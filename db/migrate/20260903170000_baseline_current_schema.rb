class BaselineCurrentSchema < ActiveRecord::Migration[8.1]
  REQUIRED_TABLES = %w[
    active_storage_attachments active_storage_blobs active_storage_variant_records
    admin_activity_logs admins advisor_feedback_submissions advisor_meeting_recaps advisors
    categories competencies competency_target_levels confidential_advisor_notes
    course_competency_targets course_grade_release_dates course_offerings courses departments domains
    feedback grade_competency_evidences grade_competency_ratings grade_import_batches
    grade_import_files grade_import_pending_rows majors notifications program_semesters program_tracks
    program_years questions site_settings student_advisor_assignments student_questions students
    survey_assignments survey_change_logs survey_legends survey_offerings survey_response_versions
    survey_sections survey_track_assignments surveys users
  ].freeze

  def up
    return if connection.data_source_exists?("users") && required_tables_present?

    application_tables = connection.tables - %w[schema_migrations ar_internal_metadata]
    if application_tables.any?
      missing = REQUIRED_TABLES.reject { |table| connection.data_source_exists?(table) }
      raise ActiveRecord::MigrationError,
            "Cannot baseline a non-empty incomplete database; missing tables: #{missing.join(', ')}"
    end

    load Rails.root.join("db/schema.rb").to_s
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "The schema baseline is restored through db/schema.rb"
  end

  private

  def required_tables_present?
    REQUIRED_TABLES.all? { |table| connection.data_source_exists?(table) }
  end
end