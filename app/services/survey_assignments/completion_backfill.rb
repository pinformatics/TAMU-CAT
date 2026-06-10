module SurveyAssignments
  # Restores missing assignment completion timestamps from existing answers.
  class CompletionBackfill
    def self.call(scope: SurveyAssignment.where(completed_at: nil))
      new(scope: scope).call
    end

    def initialize(scope:)
      @scope = scope
    end

    def call
      updated_count = 0

      @scope.includes(:student, :survey).find_each do |assignment|
        next unless assignment.student && assignment.survey

        survey_response = SurveyResponse.build(student: assignment.student, survey: assignment.survey)
        next unless survey_response.status == :submitted

        completion_time = completion_time_for(assignment, survey_response)
        assignment.update_columns(completed_at: completion_time, updated_at: Time.current)
        updated_count += 1
      end

      updated_count
    end

    private

    def completion_time_for(assignment, survey_response)
      submitted_version_time(assignment) ||
        survey_response.completion_date ||
        assignment.updated_at ||
        Time.current
    end

    def submitted_version_time(assignment)
      SurveyResponseVersion
        .where(student_id: assignment.student_id, survey_id: assignment.survey_id)
        .where.not(event: SurveyResponseVersion::DRAFT_EVENTS)
        .order(created_at: :desc, id: :desc)
        .pick(:created_at)
    end
  end
end
