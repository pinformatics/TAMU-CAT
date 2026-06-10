namespace :v6 do
  desc "Check whether the folded V6 course schema is present before QA or imports"
  task readiness: :environment do
    missing_sources = CourseCompetencyTarget::REQUIRED_DATA_SOURCES.reject do |source|
      ActiveRecord::Base.connection.data_source_exists?(source)
    end
    missing_columns = [
      [ :notifications, :event_key ],
      [ :notifications, :dedupe_key ],
      [ :notifications, :metadata ],
      [ :advisor_feedback_submissions, :submitted_feedback_signature ]
    ].reject do |table_name, column_name|
      ActiveRecord::Base.connection.column_exists?(table_name, column_name)
    end

    completion_mismatch_count = SurveyAssignment
      .where(completed_at: nil)
      .includes(:student, :survey)
      .count { |assignment| SurveyAssignments::CompletionBackfill.backfillable?(assignment) }

    puts "V6 course schema readiness"
    CourseCompetencyTarget::REQUIRED_DATA_SOURCES.each do |source|
      status = missing_sources.include?(source) ? "MISSING" : "OK"
      puts "  [#{status}] #{source}"
    end

    puts "V6 notification schema readiness"
    missing_column_labels = missing_columns.map { |table_name, column_name| "#{table_name}.#{column_name}" }
    [
      "notifications.event_key",
      "notifications.dedupe_key",
      "notifications.metadata",
      "advisor_feedback_submissions.submitted_feedback_signature"
    ].each do |label|
      status = missing_column_labels.include?(label) ? "MISSING" : "OK"
      puts "  [#{status}] #{label}"
    end

    puts "V6 survey completion readiness"
    completion_status = completion_mismatch_count.positive? ? "MISSING" : "OK"
    puts "  [#{completion_status}] assignment completed_at backfill mismatches: #{completion_mismatch_count}"

    if missing_sources.any?
      abort "Missing V6 course schema tables/views: #{missing_sources.join(', ')}"
    end

    if missing_columns.any?
      abort "Missing V6 notification schema columns: #{missing_column_labels.join(', ')}"
    end

    if completion_mismatch_count.positive?
      abort "Found #{completion_mismatch_count} submitted survey assignment(s) without completed_at. Run bin/rails survey_assignments:backfill_completed."
    end
  end
end
