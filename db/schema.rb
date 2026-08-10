# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_08_07_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_stat_statements"

  create_table "admin_activity_logs", force: :cascade do |t|
    t.bigint "admin_id", null: false
    t.string "action", null: false
    t.string "subject_type"
    t.bigint "subject_id"
    t.jsonb "metadata", default: {}, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["admin_id"], name: "index_admin_activity_logs_on_admin_id"
    t.index ["subject_type", "subject_id"], name: "index_admin_activity_logs_on_subject"
  end

  create_table "admins", primary_key: "admin_id", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "advisor_feedback_submissions", force: :cascade do |t|
    t.bigint "student_id", null: false
    t.bigint "survey_id", null: false
    t.bigint "advisor_id", null: false
    t.datetime "last_saved_at"
    t.datetime "submitted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "submitted_feedback_signature"
    t.index ["student_id", "survey_id", "advisor_id"], name: "index_feedback_submissions_on_student_survey_advisor", unique: true
    t.index ["submitted_at"], name: "index_advisor_feedback_submissions_on_submitted_at"
  end

  create_table "advisors", primary_key: "advisor_id", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "categories", force: :cascade do |t|
    t.string "name", null: false
    t.string "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "survey_id"
    t.bigint "survey_section_id"
    t.index ["survey_id"], name: "index_categories_on_survey_id"
    t.index ["survey_section_id"], name: "index_categories_on_survey_section_id"
  end

  create_table "competencies", force: :cascade do |t|
    t.bigint "domain_id", null: false
    t.string "title", null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["domain_id", "position"], name: "index_competencies_on_domain_id_and_position"
    t.index ["domain_id"], name: "index_competencies_on_domain_id"
    t.index ["title"], name: "index_competencies_on_title", unique: true
  end

  create_table "competency_target_levels", force: :cascade do |t|
    t.bigint "program_semester_id", null: false
    t.string "track", null: false
    t.integer "program_year"
    t.integer "class_of"
    t.string "competency_title", null: false
    t.integer "target_level", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "competency_id"
    t.index ["competency_id"], name: "index_competency_target_levels_on_competency_id"
    t.index ["program_semester_id", "track", "program_year", "class_of", "competency_title"], name: "index_competency_targets_unique", unique: true
    t.index ["program_semester_id"], name: "index_competency_target_levels_on_program_semester_id"
  end

  create_table "confidential_advisor_notes", force: :cascade do |t|
    t.bigint "student_id", null: false
    t.bigint "survey_id", null: false
    t.bigint "advisor_id", null: false
    t.text "body", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["advisor_id"], name: "index_confidential_advisor_notes_on_advisor_id"
    t.index ["student_id", "survey_id", "advisor_id"], name: "index_confidential_notes_on_student_survey_advisor", unique: true
    t.index ["student_id"], name: "index_confidential_advisor_notes_on_student_id"
    t.index ["survey_id"], name: "index_confidential_advisor_notes_on_survey_id"
  end

  create_table "course_competency_targets", force: :cascade do |t|
    t.bigint "course_offering_id", null: false
    t.bigint "competency_id", null: false
    t.integer "target_level", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "track"
    t.index ["competency_id"], name: "index_course_competency_targets_on_competency_id"
    t.index ["course_offering_id", "competency_id", "track"], name: "index_cct_unique_offering_competency_track", unique: true
    t.index ["course_offering_id"], name: "index_course_competency_targets_on_course_offering_id"
  end

  create_table "course_grade_release_dates", force: :cascade do |t|
    t.bigint "program_semester_id", null: false
    t.datetime "release_date"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["program_semester_id"], name: "index_course_grade_release_dates_on_program_semester_id"
    t.index ["program_semester_id"], name: "index_course_release_dates_on_program_semester_unique", unique: true
    t.index ["release_date"], name: "index_course_grade_release_dates_on_release_date"
  end

  create_table "course_offerings", force: :cascade do |t|
    t.bigint "course_id", null: false
    t.bigint "program_semester_id"
    t.string "section_number"
    t.string "source_code"
    t.boolean "active", default: true, null: false
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_course_offerings_on_active"
    t.index ["archived_at"], name: "index_course_offerings_on_archived_at"
    t.index ["course_id", "program_semester_id", "section_number"], name: "index_course_offerings_unique_by_semester", unique: true, where: "(program_semester_id IS NOT NULL)"
    t.index ["course_id", "section_number"], name: "index_course_offerings_on_course_and_section"
    t.index ["course_id"], name: "index_course_offerings_on_course_id"
    t.index ["program_semester_id"], name: "index_course_offerings_on_program_semester_id"
    t.index ["source_code"], name: "index_course_offerings_on_source_code"
  end

  create_table "courses", force: :cascade do |t|
    t.bigint "department_id", null: false
    t.string "number", null: false
    t.string "title"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_courses_on_active"
    t.index ["department_id", "number"], name: "index_courses_on_department_id_and_number", unique: true
    t.index ["department_id"], name: "index_courses_on_department_id"
  end

  create_table "departments", force: :cascade do |t|
    t.string "code", null: false
    t.string "name", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_departments_on_active"
    t.index ["code"], name: "index_departments_on_code", unique: true
  end

  create_table "domains", force: :cascade do |t|
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_domains_on_name", unique: true
    t.index ["position"], name: "index_domains_on_position"
  end

  create_table "feedback", force: :cascade do |t|
    t.bigint "student_id", null: false
    t.bigint "advisor_id", null: false
    t.bigint "category_id", null: false
    t.bigint "survey_id", null: false
    t.float "average_score"
    t.string "comments"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "question_id"
    t.index ["advisor_id"], name: "index_feedback_on_advisor_id"
    t.index ["category_id"], name: "index_feedback_on_category_id"
    t.index ["question_id"], name: "index_feedback_on_question_id"
    t.index ["student_id"], name: "index_feedback_on_student_id"
    t.index ["survey_id"], name: "index_feedback_on_survey_id"
  end

  create_table "grade_competency_evidences", force: :cascade do |t|
    t.bigint "grade_import_batch_id", null: false
    t.bigint "grade_import_file_id", null: false
    t.bigint "student_id", null: false
    t.string "competency_title", null: false
    t.string "course_code"
    t.string "assignment_name"
    t.decimal "raw_grade", precision: 8, scale: 2, null: false
    t.integer "mapped_level", null: false
    t.integer "row_number"
    t.string "source_key", null: false
    t.string "import_fingerprint", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "course_target_level"
    t.bigint "competency_id"
    t.bigint "course_offering_id"
    t.index ["competency_id"], name: "index_grade_competency_evidences_on_competency_id"
    t.index ["course_offering_id"], name: "index_grade_competency_evidences_on_course_offering_id"
    t.index ["grade_import_batch_id", "competency_title"], name: "index_grade_evidence_on_batch_competency"
    t.index ["grade_import_batch_id", "source_key"], name: "index_grade_evidence_on_batch_source_key", unique: true
    t.index ["grade_import_batch_id", "student_id"], name: "index_grade_evidence_on_batch_student"
    t.index ["grade_import_batch_id"], name: "index_grade_competency_evidences_on_grade_import_batch_id"
    t.index ["grade_import_file_id"], name: "index_grade_competency_evidences_on_grade_import_file_id"
    t.index ["import_fingerprint"], name: "index_grade_competency_evidences_on_import_fingerprint", unique: true
  end

  create_table "grade_competency_ratings", force: :cascade do |t|
    t.bigint "grade_import_batch_id", null: false
    t.bigint "student_id", null: false
    t.string "competency_title", null: false
    t.decimal "aggregated_level", precision: 4, scale: 2, null: false
    t.string "aggregation_rule", default: "max", null: false
    t.integer "evidence_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "competency_id"
    t.index ["competency_id"], name: "index_grade_competency_ratings_on_competency_id"
    t.index ["grade_import_batch_id", "student_id", "competency_title"], name: "index_grade_ratings_on_batch_student_competency", unique: true
    t.index ["grade_import_batch_id"], name: "index_grade_competency_ratings_on_grade_import_batch_id"
  end

  create_table "grade_import_batches", force: :cascade do |t|
    t.bigint "uploaded_by_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "started_at"
    t.datetime "completed_at"
    t.integer "total_files", default: 0, null: false
    t.integer "processed_files", default: 0, null: false
    t.integer "failed_files", default: 0, null: false
    t.integer "evidence_count", default: 0, null: false
    t.integer "rating_count", default: 0, null: false
    t.integer "pending_count", default: 0, null: false
    t.jsonb "summary", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "program_semester_id"
    t.index ["program_semester_id"], name: "index_grade_import_batches_on_program_semester_id"
    t.index ["status"], name: "index_grade_import_batches_on_status"
    t.index ["uploaded_by_id"], name: "index_grade_import_batches_on_uploaded_by_id"
  end

  create_table "grade_import_files", force: :cascade do |t|
    t.bigint "grade_import_batch_id", null: false
    t.string "file_name", null: false
    t.string "file_checksum", null: false
    t.string "content_type"
    t.string "status", default: "pending", null: false
    t.integer "total_rows", default: 0, null: false
    t.integer "imported_rows", default: 0, null: false
    t.integer "pending_rows", default: 0, null: false
    t.integer "error_rows", default: 0, null: false
    t.jsonb "parse_errors", default: [], null: false
    t.jsonb "parsed_content", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "course_offering_id"
    t.index ["course_offering_id"], name: "index_grade_import_files_on_course_offering_id"
    t.index ["file_checksum"], name: "index_grade_import_files_on_file_checksum"
    t.index ["grade_import_batch_id"], name: "index_grade_import_files_on_grade_import_batch_id"
    t.index ["status"], name: "index_grade_import_files_on_status"
  end

  create_table "grade_import_pending_rows", force: :cascade do |t|
    t.bigint "grade_import_batch_id", null: false
    t.bigint "grade_import_file_id", null: false
    t.bigint "matched_student_id"
    t.string "status", default: "pending_student_match", null: false
    t.string "student_identifier"
    t.string "student_identifier_type"
    t.string "student_uin"
    t.string "student_email"
    t.string "student_name"
    t.string "competency_title", null: false
    t.string "course_code"
    t.string "assignment_name"
    t.decimal "raw_grade", precision: 8, scale: 2, null: false
    t.integer "mapped_level", null: false
    t.integer "row_number"
    t.string "source_key", null: false
    t.string "import_fingerprint", null: false
    t.datetime "reconciled_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "course_target_level"
    t.bigint "competency_id"
    t.bigint "course_offering_id"
    t.index ["competency_id"], name: "index_grade_import_pending_rows_on_competency_id"
    t.index ["course_offering_id"], name: "index_grade_import_pending_rows_on_course_offering_id"
    t.index ["grade_import_batch_id", "source_key"], name: "index_grade_pending_rows_on_batch_source_key", unique: true
    t.index ["grade_import_batch_id", "status"], name: "index_grade_pending_rows_on_batch_status"
    t.index ["grade_import_batch_id", "student_email"], name: "index_grade_pending_rows_on_batch_email"
    t.index ["grade_import_batch_id", "student_uin"], name: "index_grade_pending_rows_on_batch_uin"
    t.index ["grade_import_batch_id"], name: "index_grade_import_pending_rows_on_grade_import_batch_id"
    t.index ["grade_import_file_id"], name: "index_grade_import_pending_rows_on_grade_import_file_id"
    t.index ["import_fingerprint"], name: "index_grade_import_pending_rows_on_import_fingerprint", unique: true
    t.index ["status"], name: "index_grade_import_pending_rows_on_status"
  end

  create_table "majors", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_majors_on_name", unique: true
  end

  create_table "notifications", force: :cascade do |t|
    t.string "title", null: false
    t.text "message"
    t.string "notifiable_type"
    t.bigint "notifiable_id"
    t.datetime "read_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "event_key"
    t.string "dedupe_key"
    t.jsonb "metadata", default: {}, null: false
    t.index ["event_key"], name: "index_notifications_on_event_key"
    t.index ["notifiable_type", "notifiable_id"], name: "index_notifications_on_notifiable"
    t.index ["user_id", "dedupe_key"], name: "index_notifications_unique_user_dedupe_key", unique: true, where: "(dedupe_key IS NOT NULL)"
    t.index ["user_id", "read_at"], name: "index_notifications_on_user_and_read_at"
    t.index ["user_id", "title", "notifiable_type", "notifiable_id"], name: "index_notifications_on_user_title_notifiable"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "program_semesters", force: :cascade do |t|
    t.string "name", null: false
    t.boolean "current", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "status", default: "planned", null: false
    t.date "starts_on"
    t.date "ends_on"
    t.datetime "closed_at"
    t.datetime "archived_at"
    t.index ["archived_at"], name: "index_program_semesters_on_archived_at"
    t.index ["current"], name: "index_program_semesters_on_current", where: "(current = true)"
    t.index ["name"], name: "index_program_semesters_on_name", unique: true
    t.index ["status"], name: "index_program_semesters_on_status"
  end

  create_table "program_tracks", force: :cascade do |t|
    t.string "key", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "lower((key)::text)", name: "index_program_tracks_on_lower_key", unique: true
    t.index "lower((name)::text)", name: "index_program_tracks_on_lower_name", unique: true
  end

  create_table "program_years", force: :cascade do |t|
    t.integer "value", null: false
    t.integer "position", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_program_years_on_active"
    t.index ["value"], name: "index_program_years_on_value", unique: true
  end

  create_table "questions", force: :cascade do |t|
    t.string "question_text", null: false
    t.text "description"
    t.text "tooltip_text"
    t.integer "question_order", null: false
    t.boolean "is_required", default: false, null: false
    t.string "question_type", null: false
    t.text "answer_options"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "category_id"
    t.boolean "has_evidence_field", default: false, null: false
    t.boolean "has_feedback", default: false, null: false
    t.jsonb "configuration", default: {}, null: false
    t.integer "program_target_level"
    t.bigint "parent_question_id"
    t.integer "sub_question_order", default: 0, null: false
    t.index ["category_id", "question_order"], name: "index_questions_on_category_id_and_question_order"
    t.index ["category_id"], name: "index_questions_on_category_id"
    t.index ["parent_question_id", "sub_question_order"], name: "index_questions_on_parent_and_sub_order"
    t.index ["parent_question_id"], name: "index_questions_on_parent_question_id"
    t.index ["question_order"], name: "index_questions_on_question_order"
  end

  create_table "site_settings", force: :cascade do |t|
    t.string "key", null: false
    t.string "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_site_settings_on_key", unique: true
  end

  create_table "student_advisor_assignments", force: :cascade do |t|
    t.bigint "student_id", null: false
    t.bigint "advisor_id"
    t.date "starts_on", null: false
    t.date "ends_on"
    t.boolean "primary_assignment", default: true, null: false
    t.bigint "assigned_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["advisor_id"], name: "index_student_advisor_assignments_on_advisor_id"
    t.index ["assigned_by_id"], name: "index_student_advisor_assignments_on_assigned_by_id"
    t.index ["student_id", "starts_on"], name: "index_student_advisor_assignments_on_student_id_and_starts_on"
    t.index ["student_id"], name: "idx_student_advisor_assignments_current_primary", unique: true, where: "((primary_assignment = true) AND (ends_on IS NULL))"
    t.index ["student_id"], name: "index_student_advisor_assignments_on_student_id"
  end

  create_table "student_questions", force: :cascade do |t|
    t.bigint "student_id", null: false
    t.bigint "advisor_id"
    t.bigint "question_id", null: false
    t.string "response_value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["advisor_id"], name: "index_student_questions_on_advisor_id"
    t.index ["question_id"], name: "index_student_questions_on_question_id"
    t.index ["student_id", "question_id"], name: "index_student_questions_on_student_id_and_question_id", unique: true
    t.index ["student_id"], name: "index_student_questions_on_student_id"
  end

  create_table "students", primary_key: "student_id", force: :cascade do |t|
    t.string "uin"
    t.bigint "advisor_id"
    t.string "track"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "major"
    t.integer "program_year"
    t.string "assignment_group"
    t.string "status", default: "active", null: false
    t.datetime "graduated_at"
    t.datetime "archived_at"
    t.text "archive_reason"
    t.bigint "archived_by_id"
    t.index ["advisor_id"], name: "index_students_on_advisor_id"
    t.index ["archived_at"], name: "index_students_on_archived_at"
    t.index ["archived_by_id"], name: "index_students_on_archived_by_id"
    t.index ["assignment_group"], name: "index_students_on_assignment_group"
    t.index ["graduated_at"], name: "index_students_on_graduated_at"
    t.index ["program_year"], name: "index_students_on_program_year"
    t.index ["status"], name: "index_students_on_status"
    t.index ["uin"], name: "index_students_on_uin", unique: true, where: "(uin IS NOT NULL)"
  end

  create_table "survey_assignments", force: :cascade do |t|
    t.bigint "survey_id", null: false
    t.bigint "student_id", null: false
    t.bigint "advisor_id"
    t.datetime "assigned_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "available_from"
    t.datetime "available_until"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "manual", default: false, null: false
    t.index ["manual"], name: "index_survey_assignments_on_manual"
    t.index ["survey_id", "student_id"], name: "index_survey_assignments_on_survey_and_student", unique: true
    t.index ["survey_id"], name: "index_survey_assignments_on_survey_id"
  end

  create_table "survey_change_logs", force: :cascade do |t|
    t.bigint "survey_id"
    t.bigint "admin_id", null: false
    t.string "action", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "survey_title_snapshot"
    t.index ["survey_id"], name: "index_survey_change_logs_on_survey_id"
  end

  create_table "survey_legends", force: :cascade do |t|
    t.bigint "survey_id", null: false
    t.string "title"
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["survey_id"], name: "index_survey_legends_on_survey_id", unique: true
  end

  create_table "survey_offerings", force: :cascade do |t|
    t.bigint "survey_id", null: false
    t.string "track", null: false
    t.integer "class_of"
    t.string "stage", null: false
    t.string "assignment_group"
    t.datetime "portfolio_due_date"
    t.datetime "available_from"
    t.datetime "available_until"
    t.date "review_meetings_start"
    t.date "review_meetings_end"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["survey_id", "track", "class_of", "stage", "assignment_group"], name: "index_survey_offerings_unique", unique: true
    t.index ["survey_id"], name: "index_survey_offerings_on_survey_id"
    t.index ["track", "class_of", "active"], name: "index_survey_offerings_on_track_class_of_active"
    t.index ["track", "class_of", "assignment_group", "active"], name: "index_survey_offerings_on_track_class_of_group_active"
  end

  create_table "survey_response_versions", force: :cascade do |t|
    t.bigint "student_id", null: false
    t.bigint "survey_id", null: false
    t.bigint "advisor_id"
    t.bigint "survey_assignment_id"
    t.bigint "actor_user_id"
    t.string "actor_role"
    t.string "event", null: false
    t.jsonb "answers", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_user_id"], name: "index_survey_response_versions_on_actor_user_id"
    t.index ["student_id", "survey_id", "created_at"], name: "index_srv_versions_on_student_survey_created"
    t.index ["survey_assignment_id"], name: "index_survey_response_versions_on_survey_assignment_id"
  end

  create_table "survey_sections", force: :cascade do |t|
    t.bigint "survey_id", null: false
    t.string "title", null: false
    t.text "description"
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["survey_id", "position"], name: "index_survey_sections_on_survey_id_and_position"
    t.index ["survey_id"], name: "index_survey_sections_on_survey_id"
  end

  create_table "survey_track_assignments", force: :cascade do |t|
    t.bigint "survey_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "track", null: false
    t.index ["survey_id", "track"], name: "index_survey_track_assignments_on_survey_id_and_track", unique: true
    t.index ["survey_id"], name: "index_survey_track_assignments_on_survey_id"
  end

  create_table "surveys", force: :cascade do |t|
    t.string "title", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "track"
    t.text "description"
    t.boolean "is_active", default: true, null: false
    t.bigint "created_by_id"
    t.bigint "program_semester_id", null: false
    t.datetime "available_from"
    t.datetime "available_until"
    t.boolean "show_course_competencies_with_survey", default: false, null: false
    t.boolean "advisor_numeric_feedback_enabled", default: false, null: false
    t.index "lower((title)::text), program_semester_id", name: "index_surveys_on_lower_title_and_program_semester", unique: true
    t.index ["available_from"], name: "index_surveys_on_available_from"
    t.index ["available_until"], name: "index_surveys_on_available_until"
    t.index ["created_by_id"], name: "index_surveys_on_created_by_id"
    t.index ["is_active"], name: "index_surveys_on_is_active"
    t.index ["program_semester_id"], name: "index_surveys_on_program_semester_id"
    t.index ["track"], name: "index_surveys_on_track"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.string "name", null: false
    t.string "uid"
    t.string "avatar_url"
    t.string "role", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "failed_mfa_attempts", default: 0, null: false
    t.datetime "mfa_locked_at"
    t.string "language"
    t.boolean "notifications_enabled", default: true, null: false
    t.integer "text_scale_percent", default: 100, null: false
    t.boolean "in_app_notifications_enabled", default: true, null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["role"], name: "index_users_on_role"
    t.index ["uid"], name: "index_users_on_uid", unique: true
  end

  add_foreign_key "admin_activity_logs", "users", column: "admin_id", on_delete: :cascade
  add_foreign_key "admins", "users", column: "admin_id", on_delete: :cascade
  add_foreign_key "advisor_feedback_submissions", "advisors", primary_key: "advisor_id", on_delete: :cascade
  add_foreign_key "advisor_feedback_submissions", "students", primary_key: "student_id", on_delete: :cascade
  add_foreign_key "advisor_feedback_submissions", "surveys", on_delete: :cascade
  add_foreign_key "advisors", "users", column: "advisor_id", on_delete: :cascade
  add_foreign_key "categories", "survey_sections", on_delete: :nullify
  add_foreign_key "categories", "surveys"
  add_foreign_key "competencies", "domains"
  add_foreign_key "competency_target_levels", "competencies"
  add_foreign_key "competency_target_levels", "program_semesters"
  add_foreign_key "confidential_advisor_notes", "advisors", primary_key: "advisor_id", on_delete: :cascade
  add_foreign_key "confidential_advisor_notes", "students", primary_key: "student_id", on_delete: :cascade
  add_foreign_key "confidential_advisor_notes", "surveys", on_delete: :cascade
  add_foreign_key "course_competency_targets", "competencies"
  add_foreign_key "course_competency_targets", "course_offerings"
  add_foreign_key "course_grade_release_dates", "program_semesters"
  add_foreign_key "course_offerings", "courses", on_delete: :cascade
  add_foreign_key "course_offerings", "program_semesters"
  add_foreign_key "courses", "departments"
  add_foreign_key "feedback", "advisors", primary_key: "advisor_id", on_delete: :cascade
  add_foreign_key "feedback", "categories", on_delete: :cascade
  add_foreign_key "feedback", "questions"
  add_foreign_key "feedback", "students", primary_key: "student_id", on_delete: :cascade
  add_foreign_key "feedback", "surveys", on_delete: :cascade
  add_foreign_key "grade_competency_evidences", "competencies"
  add_foreign_key "grade_competency_evidences", "course_offerings"
  add_foreign_key "grade_competency_evidences", "grade_import_batches", on_delete: :cascade
  add_foreign_key "grade_competency_evidences", "grade_import_files", on_delete: :cascade
  add_foreign_key "grade_competency_evidences", "students", primary_key: "student_id", on_delete: :cascade
  add_foreign_key "grade_competency_ratings", "competencies"
  add_foreign_key "grade_competency_ratings", "grade_import_batches", on_delete: :cascade
  add_foreign_key "grade_competency_ratings", "students", primary_key: "student_id", on_delete: :cascade
  add_foreign_key "grade_import_batches", "program_semesters"
  add_foreign_key "grade_import_batches", "users", column: "uploaded_by_id", on_delete: :cascade
  add_foreign_key "grade_import_files", "course_offerings"
  add_foreign_key "grade_import_files", "grade_import_batches", on_delete: :cascade
  add_foreign_key "grade_import_pending_rows", "competencies"
  add_foreign_key "grade_import_pending_rows", "course_offerings"
  add_foreign_key "grade_import_pending_rows", "grade_import_batches", on_delete: :cascade
  add_foreign_key "grade_import_pending_rows", "grade_import_files", on_delete: :cascade
  add_foreign_key "grade_import_pending_rows", "students", column: "matched_student_id", primary_key: "student_id", on_delete: :nullify
  add_foreign_key "notifications", "users", on_delete: :cascade
  add_foreign_key "questions", "categories"
  add_foreign_key "questions", "questions", column: "parent_question_id"
  add_foreign_key "student_advisor_assignments", "advisors", primary_key: "advisor_id", on_delete: :nullify
  add_foreign_key "student_advisor_assignments", "students", primary_key: "student_id", on_delete: :cascade
  add_foreign_key "student_advisor_assignments", "users", column: "assigned_by_id", on_delete: :nullify
  add_foreign_key "student_questions", "advisors", primary_key: "advisor_id", on_delete: :cascade
  add_foreign_key "student_questions", "questions", on_delete: :cascade
  add_foreign_key "student_questions", "students", primary_key: "student_id", on_delete: :cascade
  add_foreign_key "students", "advisors", primary_key: "advisor_id", on_delete: :cascade
  add_foreign_key "students", "users", column: "archived_by_id", on_delete: :nullify
  add_foreign_key "students", "users", column: "student_id", on_delete: :cascade
  add_foreign_key "survey_assignments", "advisors", primary_key: "advisor_id", on_delete: :nullify
  add_foreign_key "survey_assignments", "students", primary_key: "student_id", on_delete: :cascade
  add_foreign_key "survey_assignments", "surveys", on_delete: :cascade
  add_foreign_key "survey_change_logs", "surveys", on_delete: :nullify
  add_foreign_key "survey_change_logs", "users", column: "admin_id"
  add_foreign_key "survey_legends", "surveys"
  add_foreign_key "survey_offerings", "surveys", on_delete: :cascade
  add_foreign_key "survey_response_versions", "students", primary_key: "student_id"
  add_foreign_key "survey_response_versions", "survey_assignments"
  add_foreign_key "survey_response_versions", "surveys"
  add_foreign_key "survey_sections", "surveys", on_delete: :cascade
  add_foreign_key "survey_track_assignments", "surveys", on_delete: :cascade
  add_foreign_key "surveys", "program_semesters"
  add_foreign_key "surveys", "users", column: "created_by_id"
end
