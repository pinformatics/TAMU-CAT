module SurveyAssignments
  # Restores missing assignment completion timestamps from existing answers.
  class CompletionBackfill
    SUBMITTED_VERSION_EVENTS = %w[submitted revised admin_edited].freeze

    attr_reader :stats

    def self.call(scope: SurveyAssignment.where(completed_at: nil))
      new(scope: scope).call
    end

    def self.backfillable?(assignment)
      new(scope: SurveyAssignment.none).backfill_source_for(assignment).present?
    end

    def initialize(scope:)
      @scope = scope
      @stats = blank_stats
    end

    def call
      @stats = blank_stats

      @scope.includes(:student, :survey).find_each do |assignment|
        @stats[:checked] += 1

        source = backfill_source_for(assignment)
        unless source
          @stats[:skipped] += 1
          next
        end

        assignment.update_columns(completed_at: source[:completed_at], updated_at: Time.current)
        @stats[:updated] += 1
        @stats[source[:source] == :version ? :from_versions : :from_answer_sets] += 1
      end

      @stats[:updated]
    end

    def backfill_source_for(assignment)
      return unless assignment.student && assignment.survey

      if (version_time = submitted_version_time(assignment))
        return { source: :version, completed_at: version_time }
      end

      survey_response = SurveyResponse.build(student: assignment.student, survey: assignment.survey)
      return unless survey_response.status == :submitted

      {
        source: :answer_set,
        completed_at: completion_time_for(assignment, survey_response)
      }
    end

    private

    def blank_stats
      {
        checked: 0,
        updated: 0,
        from_versions: 0,
        from_answer_sets: 0,
        skipped: 0
      }
    end

    def completion_time_for(assignment, survey_response)
      submitted_version_time(assignment) ||
        survey_response.completion_date ||
        assignment.updated_at ||
        Time.current
    end

    def submitted_version_time(assignment)
      SurveyResponseVersion
        .where(student_id: assignment.student_id, survey_id: assignment.survey_id)
        .where(event: SUBMITTED_VERSION_EVENTS)
        .order(created_at: :desc, id: :desc)
        .pick(:created_at)
    end
  end
end
