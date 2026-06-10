# frozen_string_literal: true

module SurveyAssignments
  # Ensures a student's survey assignments mirror the surveys associated with
  # their current track selection and class year ("Class of"). When either value is blank,
  # the auto assigner leaves the assignment list untouched so that a first-time
  # login does not receive surveys prematurely.
  class AutoAssigner
    # @param student [Student]
    # @param track [String, nil]
    # @param class_of [Integer, String, nil]
    # @param program_year [Integer, String, nil] legacy alias
    # @return [void]
    def self.call(student:, track: nil, class_of: nil, program_year: nil)
      new(student:, track:, class_of:, program_year:).call
    end

    def initialize(student:, track: nil, class_of: nil, program_year: nil)
      @student = student
      @track = (track.presence || student&.track_key).to_s.strip
      @class_of = class_of.presence || student&.program_year

      # Backward compatibility: some older callers may still pass program_year.
      @class_of = @class_of.presence || program_year.presence
    end

    def call
      return unless student

      if track.blank? || class_of.blank?
        # Track selection not available yet; remove any outdated managed
        # assignments so that onboarding students start with a clean slate.
        remove_managed_assignments!(allowed_ids: [])
        reset_student_assignment_cache!
        return
      end

      surveys, active_ids, offering_available_from, offering_available_until = surveys_for_student

      ActiveRecord::Base.transaction do
        remove_managed_assignments!(allowed_ids: active_ids)
        assign_missing_surveys!(
          surveys,
          offering_available_from: offering_available_from,
          offering_available_until: offering_available_until
        )
      end

      reset_student_assignment_cache!
    end

    private

    attr_reader :student, :track, :class_of

    def surveys_for_student
      if SurveyOffering.data_source_ready? && SurveyOffering.active.exists?
        offerings = SurveyOffering.for_student(
          track_key: track,
          class_of: class_of,
          assignment_group: student.respond_to?(:assignment_group) ? student.assignment_group : nil
        )
          .includes(:survey)

        surveys = offerings.map(&:survey).compact.uniq
        active_ids = surveys.map(&:id)
        available_from = offerings.each_with_object({}) do |offering, memo|
          memo[offering.survey_id] = offering.available_from
        end

        available_until = offerings.each_with_object({}) do |offering, memo|
          memo[offering.survey_id] = offering.available_until
        end

        return [ surveys, active_ids, available_from, available_until ]
      end

      surveys = surveys_for_track
      [ surveys, surveys.map(&:id), {}, {} ]
    end

    def surveys_for_track
      current_semester = ProgramSemester.current&.name.to_s.strip
      if current_semester.blank?
        current_semester = ProgramSemester.ordered.to_a.last&.name.to_s.strip
      end

      return Survey.none if current_semester.blank?

      scheduled_titles = scheduled_titles_for(track: track, class_of: class_of)
      if scheduled_titles.any?
        scheduled_scope = Survey.active
          .joins(:program_semester)
          .where("LOWER(program_semesters.name) = ?", current_semester.downcase)
          .where(title: scheduled_titles)
          .distinct

        return scheduled_scope if scheduled_scope.exists?
      end

      Survey.active
        .joins(:program_semester)
        .where("LOWER(program_semesters.name) = ?", current_semester.downcase)
            .joins(:track_assignments)
            .where("LOWER(survey_track_assignments.track) = ?", track.downcase)
            .distinct
    end

    def scheduled_titles_for(track:, class_of:)
      return [] if track.blank? || class_of.blank?

      normalized_track = track.to_s.strip.downcase
      cohort = class_of.to_i
      current_year = current_program_year
      return [] if current_year.blank?

      case normalized_track
      when "residential"
        case cohort
        when current_year + 1
          [ "RMHA Initial Competency Survey" ]
        when current_year
          [ "RMHA Mid-point Competency Survey", "RMHA Final Competency Survey" ]
        else
          []
        end
      when "executive"
        case cohort
        when current_year + 1
          [ "EMHA Mid-point Competency Survey" ]
        when current_year
          [ "EMHA Final Competency Survey" ]
        else
          []
        end
      else
        []
      end
    end

    def remove_managed_assignments!(allowed_ids: [])
      scope = assignment_scope
      scope = scope.where(manual: false) if SurveyAssignment.column_names.include?("manual")

      if SurveyOffering.data_source_ready? && SurveyOffering.active.exists?
        # When offerings drive assignment, treat *any* survey with an offering as managed.
        # This ensures changing track/class_of removes outdated managed assignments.
        scope = scope
          .joins(:survey)
          .joins("INNER JOIN survey_offerings ON survey_offerings.survey_id = surveys.id")
          .distinct
      else
        scope = scope.joins(survey: :track_assignments).distinct
      end

      scope = scope.where.not(survey_id: allowed_ids) if allowed_ids.present?
      scope = scope.where(completed_at: nil) # completed assignments double as an audit log
      scope.find_each(&:destroy!)
    end

    def assign_missing_surveys!(
      surveys,
      offering_available_from: {},
      offering_available_until: {}
    )
      existing = assignment_scope.index_by(&:survey_id)

      surveys.each do |survey|
        assignment = existing[survey.id] || SurveyAssignment.new(student_id: student.student_id, survey: survey)
        assignment.advisor_id ||= student.advisor_id
        assignment.assigned_at ||= Time.zone.now

        manual_assignment = assignment.persisted? &&
                            SurveyAssignment.column_names.include?("manual") &&
                            assignment.respond_to?(:manual?) &&
                            assignment.manual?

        if assignment.respond_to?(:available_from) && survey.respond_to?(:available_from)
          unless manual_assignment && assignment.available_from.present?
            assignment.available_from = if offering_available_from.key?(survey.id)
              offering_available_from[survey.id]
            else
              survey.available_from
            end
          end
        end

        if assignment.respond_to?(:available_until) && survey.respond_to?(:available_until)
          unless manual_assignment && assignment.available_until.present?
            assignment.available_until = if offering_available_until.key?(survey.id)
              offering_available_until[survey.id]
            else
              survey.available_until
            end
          end
        end

        assignment.save! if assignment.new_record? || assignment.changed?
      end
    end

    def assignment_scope
      SurveyAssignment.where(student_id: student.student_id)
    end

    def current_program_year
      semester_name = ProgramSemester.current&.name.to_s
      year_match = semester_name.match(/(\d{4})/)
      year_match ? year_match[1].to_i : nil
    end

    def reset_student_assignment_cache!
      association = student.association(:survey_assignments)
      association.reset if association.loaded?
    end
  end
end
