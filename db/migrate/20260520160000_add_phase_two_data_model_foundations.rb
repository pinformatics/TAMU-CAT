class AddPhaseTwoDataModelFoundations < ActiveRecord::Migration[8.0]
  DEPARTMENT_NAMES = {
    "PHPM" => "Public Hlth Pol & Mgmt"
  }.freeze

  KNOWN_COURSE_TITLES = {
    [ "PHPM", "633" ] => "Health Law and Ethics"
  }.freeze

  COURSE_CODE_PATTERN = /\A\s*([A-Z]{2,5})[\s_-]*(\d{3})(?:[\s_-]*(\d{3}))?\s*\z/i.freeze

  def up
    add_user_notification_preferences
    add_notification_event_columns
    add_advisor_feedback_submission_signature
    add_student_lifecycle_columns
    add_semester_lifecycle_columns
    create_course_catalog_tables
    create_course_competency_targets
    add_canonical_references
    backfill_competency_references
    backfill_course_catalog
    create_student_advisor_assignment_history
  end

  def down
    drop_table :student_advisor_assignments if table_exists?(:student_advisor_assignments)

    remove_canonical_references

    drop_table :course_competency_targets if table_exists?(:course_competency_targets)
    drop_table :course_offerings if table_exists?(:course_offerings)
    drop_table :courses if table_exists?(:courses)
    drop_table :departments if table_exists?(:departments)

    remove_reference :students, :archived_by, foreign_key: { to_table: :users } if column_exists?(:students, :archived_by_id)
    remove_column :students, :archive_reason if column_exists?(:students, :archive_reason)
    remove_column :students, :archived_at if column_exists?(:students, :archived_at)
    remove_column :students, :graduated_at if column_exists?(:students, :graduated_at)
    remove_column :students, :status if column_exists?(:students, :status)

    remove_column :program_semesters, :archived_at if column_exists?(:program_semesters, :archived_at)
    remove_column :program_semesters, :closed_at if column_exists?(:program_semesters, :closed_at)
    remove_column :program_semesters, :ends_on if column_exists?(:program_semesters, :ends_on)
    remove_column :program_semesters, :starts_on if column_exists?(:program_semesters, :starts_on)
    remove_column :program_semesters, :status if column_exists?(:program_semesters, :status)

    remove_column :users, :in_app_notifications_enabled if column_exists?(:users, :in_app_notifications_enabled)
    remove_notification_event_columns
    remove_column :advisor_feedback_submissions, :submitted_feedback_signature if column_exists?(:advisor_feedback_submissions, :submitted_feedback_signature)
  end

  private

  def add_notification_event_columns
    add_column :notifications, :event_key, :string unless column_exists?(:notifications, :event_key)
    add_column :notifications, :dedupe_key, :string unless column_exists?(:notifications, :dedupe_key)
    add_column :notifications, :metadata, :jsonb, null: false, default: {} unless column_exists?(:notifications, :metadata)

    remove_index :notifications, name: "index_notifications_unique_per_user" if index_with_name_exists?(:notifications, "index_notifications_unique_per_user")

    add_index :notifications,
              [ :user_id, :title, :notifiable_type, :notifiable_id ],
              name: "index_notifications_on_user_title_notifiable" unless index_with_name_exists?(:notifications, "index_notifications_on_user_title_notifiable")
    add_index :notifications, :event_key unless index_exists?(:notifications, :event_key)
    add_index :notifications,
              [ :user_id, :dedupe_key ],
              unique: true,
              where: "dedupe_key IS NOT NULL",
              name: "index_notifications_unique_user_dedupe_key" unless index_with_name_exists?(:notifications, "index_notifications_unique_user_dedupe_key")
  end

  def remove_notification_event_columns
    remove_index :notifications, name: "index_notifications_unique_user_dedupe_key" if index_with_name_exists?(:notifications, "index_notifications_unique_user_dedupe_key")
    remove_index :notifications, column: :event_key if index_exists?(:notifications, :event_key)
    remove_index :notifications, name: "index_notifications_on_user_title_notifiable" if index_with_name_exists?(:notifications, "index_notifications_on_user_title_notifiable")

    add_index :notifications,
              [ :user_id, :title, :notifiable_type, :notifiable_id ],
              unique: true,
              name: "index_notifications_unique_per_user" unless index_with_name_exists?(:notifications, "index_notifications_unique_per_user")

    remove_column :notifications, :metadata if column_exists?(:notifications, :metadata)
    remove_column :notifications, :dedupe_key if column_exists?(:notifications, :dedupe_key)
    remove_column :notifications, :event_key if column_exists?(:notifications, :event_key)
  end

  def index_with_name_exists?(table_name, index_name)
    connection.indexes(table_name).any? { |index| index.name == index_name }
  end

  def add_advisor_feedback_submission_signature
    return if column_exists?(:advisor_feedback_submissions, :submitted_feedback_signature)

    add_column :advisor_feedback_submissions, :submitted_feedback_signature, :text
  end

  def add_user_notification_preferences
    return if column_exists?(:users, :in_app_notifications_enabled)

    add_column :users, :in_app_notifications_enabled, :boolean, null: false, default: true
  end

  def add_student_lifecycle_columns
    add_column :students, :status, :string, null: false, default: "active" unless column_exists?(:students, :status)
    add_column :students, :graduated_at, :datetime unless column_exists?(:students, :graduated_at)
    add_column :students, :archived_at, :datetime unless column_exists?(:students, :archived_at)
    add_column :students, :archive_reason, :text unless column_exists?(:students, :archive_reason)

    unless column_exists?(:students, :archived_by_id)
      add_reference :students, :archived_by, foreign_key: { to_table: :users, on_delete: :nullify }
    end

    add_index :students, :status unless index_exists?(:students, :status)
    add_index :students, :graduated_at unless index_exists?(:students, :graduated_at)
    add_index :students, :archived_at unless index_exists?(:students, :archived_at)
  end

  def add_semester_lifecycle_columns
    add_column :program_semesters, :status, :string, null: false, default: "planned" unless column_exists?(:program_semesters, :status)
    add_column :program_semesters, :starts_on, :date unless column_exists?(:program_semesters, :starts_on)
    add_column :program_semesters, :ends_on, :date unless column_exists?(:program_semesters, :ends_on)
    add_column :program_semesters, :closed_at, :datetime unless column_exists?(:program_semesters, :closed_at)
    add_column :program_semesters, :archived_at, :datetime unless column_exists?(:program_semesters, :archived_at)

    add_index :program_semesters, :status unless index_exists?(:program_semesters, :status)
    add_index :program_semesters, :archived_at unless index_exists?(:program_semesters, :archived_at)

    execute <<~SQL.squish
      UPDATE program_semesters
      SET status = CASE WHEN current = TRUE THEN 'current' ELSE 'closed' END
      WHERE status = 'planned'
    SQL
  end

  def create_course_catalog_tables
    unless table_exists?(:departments)
      create_table :departments do |t|
        t.string :code, null: false
        t.string :name, null: false
        t.boolean :active, null: false, default: true

        t.timestamps
      end

      add_index :departments, :code, unique: true
      add_index :departments, :active
    end

    unless table_exists?(:courses)
      create_table :courses do |t|
        t.references :department, null: false, foreign_key: true
        t.string :number, null: false
        t.string :title
        t.boolean :active, null: false, default: true

        t.timestamps
      end

      add_index :courses, [ :department_id, :number ], unique: true
      add_index :courses, :active
    end

    return if table_exists?(:course_offerings)

    create_table :course_offerings do |t|
      t.references :course, null: false, foreign_key: { on_delete: :cascade }
      t.references :program_semester, foreign_key: true
      t.string :section_number
      t.string :source_code
      t.boolean :active, null: false, default: true
      t.datetime :archived_at

      t.timestamps
    end

    add_index :course_offerings, [ :course_id, :program_semester_id, :section_number ],
              unique: true,
              where: "program_semester_id IS NOT NULL",
              name: "index_course_offerings_unique_by_semester"
    add_index :course_offerings, [ :course_id, :section_number ],
              name: "index_course_offerings_on_course_and_section"
    add_index :course_offerings, :source_code
    add_index :course_offerings, :active
    add_index :course_offerings, :archived_at
  end

  def create_course_competency_targets
    return if table_exists?(:course_competency_targets)

    create_table :course_competency_targets do |t|
      t.references :course_offering, null: false, foreign_key: true
      t.references :competency, null: false, foreign_key: true
      t.integer :target_level, null: false

      t.timestamps
    end

    add_index :course_competency_targets,
              [ :course_offering_id, :competency_id ],
              unique: true,
              name: "index_course_competency_targets_unique_offering_competency"
  end

  def add_canonical_references
    add_reference_unless_exists(:competency_target_levels, :competency, foreign_key: true)
    add_reference_unless_exists(:grade_competency_evidences, :competency, foreign_key: true)
    add_reference_unless_exists(:grade_competency_ratings, :competency, foreign_key: true)
    add_reference_unless_exists(:grade_import_pending_rows, :competency, foreign_key: true)
    add_reference_unless_exists(:grade_import_files, :course_offering, foreign_key: true)
    add_reference_unless_exists(:grade_competency_evidences, :course_offering, foreign_key: true)
    add_reference_unless_exists(:grade_import_pending_rows, :course_offering, foreign_key: true)
  end

  def remove_canonical_references
    remove_reference_if_exists(:grade_import_pending_rows, :course_offering, foreign_key: true)
    remove_reference_if_exists(:grade_competency_evidences, :course_offering, foreign_key: true)
    remove_reference_if_exists(:grade_import_files, :course_offering, foreign_key: true)
    remove_reference_if_exists(:grade_import_pending_rows, :competency, foreign_key: true)
    remove_reference_if_exists(:grade_competency_ratings, :competency, foreign_key: true)
    remove_reference_if_exists(:grade_competency_evidences, :competency, foreign_key: true)
    remove_reference_if_exists(:competency_target_levels, :competency, foreign_key: true)
  end

  def add_reference_unless_exists(table_name, reference_name, options)
    return if column_exists?(table_name, :"#{reference_name}_id")

    add_reference table_name, reference_name, **options
  end

  def remove_reference_if_exists(table_name, reference_name, options)
    return unless column_exists?(table_name, :"#{reference_name}_id")

    remove_reference table_name, reference_name, **options
  end

  def backfill_competency_references
    [
      :competency_target_levels,
      :grade_competency_evidences,
      :grade_competency_ratings,
      :grade_import_pending_rows
    ].each do |table_name|
      next unless column_exists?(table_name, :competency_id)

      execute <<~SQL.squish
        UPDATE #{table_name}
        SET competency_id = competencies.id
        FROM competencies
        WHERE #{table_name}.competency_id IS NULL
          AND #{normalized_competency_sql("#{table_name}.competency_title")}
            = #{normalized_competency_sql("competencies.title")}
      SQL
    end
  end

  def backfill_course_catalog
    course_sources.each do |source|
      parsed = parse_course_code(source["course_code"])
      next if parsed.blank?

      department_id = upsert_department(parsed[:department_code])
      title = course_title_for(parsed, source["file_name"])
      course_id = upsert_course(department_id, parsed[:course_number], title)
      offering_id = upsert_course_offering(
        course_id,
        source["program_semester_id"],
        parsed[:section_number],
        parsed[:source_code]
      )

      update_course_offering_references(
        table_name: source["table_name"],
        course_code: source["course_code"],
        program_semester_id: source["program_semester_id"],
        course_offering_id: offering_id
      )

      update_grade_file_course_offering(source["grade_import_file_id"], offering_id)
    end
  end

  def course_sources
    sources = []

    if column_exists?(:grade_competency_evidences, :course_offering_id)
      sources.concat(select_all(<<~SQL.squish).to_a)
        SELECT DISTINCT
          'grade_competency_evidences' AS table_name,
          grade_competency_evidences.course_code,
          grade_competency_evidences.grade_import_file_id,
          grade_import_batches.program_semester_id,
          grade_import_files.file_name
        FROM grade_competency_evidences
        INNER JOIN grade_import_batches
          ON grade_import_batches.id = grade_competency_evidences.grade_import_batch_id
        INNER JOIN grade_import_files
          ON grade_import_files.id = grade_competency_evidences.grade_import_file_id
        WHERE grade_competency_evidences.course_code IS NOT NULL
          AND grade_competency_evidences.course_code <> ''
      SQL
    end

    if column_exists?(:grade_import_pending_rows, :course_offering_id)
      sources.concat(select_all(<<~SQL.squish).to_a)
        SELECT DISTINCT
          'grade_import_pending_rows' AS table_name,
          grade_import_pending_rows.course_code,
          grade_import_pending_rows.grade_import_file_id,
          grade_import_batches.program_semester_id,
          grade_import_files.file_name
        FROM grade_import_pending_rows
        INNER JOIN grade_import_batches
          ON grade_import_batches.id = grade_import_pending_rows.grade_import_batch_id
        INNER JOIN grade_import_files
          ON grade_import_files.id = grade_import_pending_rows.grade_import_file_id
        WHERE grade_import_pending_rows.course_code IS NOT NULL
          AND grade_import_pending_rows.course_code <> ''
      SQL
    end

    sources.uniq { |source| [ source["table_name"], source["course_code"], source["program_semester_id"], source["grade_import_file_id"] ] }
  end

  def parse_course_code(value)
    match = COURSE_CODE_PATTERN.match(value.to_s)
    return if match.blank?

    department_code = match[1].upcase
    course_number = match[2]
    section_number = match[3].presence
    source_code = [ department_code, course_number, section_number ].compact.join("-")

    {
      department_code: department_code,
      course_number: course_number,
      section_number: section_number,
      source_code: source_code
    }
  end

  def upsert_department(code)
    name = DEPARTMENT_NAMES.fetch(code, code)
    quoted_code = quote(code)
    quoted_name = quote(name)

    execute <<~SQL.squish
      INSERT INTO departments (code, name, active, created_at, updated_at)
      VALUES (#{quoted_code}, #{quoted_name}, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      ON CONFLICT (code) DO UPDATE
      SET name = EXCLUDED.name,
          active = TRUE,
          updated_at = CURRENT_TIMESTAMP
    SQL

    select_value("SELECT id FROM departments WHERE code = #{quoted_code}")
  end

  def upsert_course(department_id, number, title)
    quoted_number = quote(number)
    quoted_title = title.present? ? quote(title) : "NULL"

    execute <<~SQL.squish
      INSERT INTO courses (department_id, number, title, active, created_at, updated_at)
      VALUES (#{department_id}, #{quoted_number}, #{quoted_title}, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      ON CONFLICT (department_id, number) DO UPDATE
      SET title = COALESCE(NULLIF(courses.title, ''), EXCLUDED.title),
          active = TRUE,
          updated_at = CURRENT_TIMESTAMP
    SQL

    select_value(<<~SQL.squish)
      SELECT id
      FROM courses
      WHERE department_id = #{department_id}
        AND number = #{quoted_number}
    SQL
  end

  def upsert_course_offering(course_id, program_semester_id, section_number, source_code)
    quoted_section = section_number.present? ? quote(section_number) : "NULL"
    quoted_source_code = quote(source_code)
    semester_condition = program_semester_id.present? ? "program_semester_id = #{program_semester_id}" : "program_semester_id IS NULL"
    semester_value = program_semester_id.presence || "NULL"

    existing_id = select_value(<<~SQL.squish)
      SELECT id
      FROM course_offerings
      WHERE course_id = #{course_id}
        AND #{semester_condition}
        AND #{section_number.present? ? "section_number = #{quoted_section}" : "section_number IS NULL"}
      LIMIT 1
    SQL

    return existing_id if existing_id.present?

    execute <<~SQL.squish
      INSERT INTO course_offerings (
        course_id,
        program_semester_id,
        section_number,
        source_code,
        active,
        created_at,
        updated_at
      )
      VALUES (
        #{course_id},
        #{semester_value},
        #{quoted_section},
        #{quoted_source_code},
        TRUE,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL

    select_value(<<~SQL.squish)
      SELECT id
      FROM course_offerings
      WHERE course_id = #{course_id}
        AND #{semester_condition}
        AND #{section_number.present? ? "section_number = #{quoted_section}" : "section_number IS NULL"}
      LIMIT 1
    SQL
  end

  def update_course_offering_references(table_name:, course_code:, program_semester_id:, course_offering_id:)
    quoted_code = quote(course_code)
    semester_condition = program_semester_id.present? ? "grade_import_batches.program_semester_id = #{program_semester_id}" : "grade_import_batches.program_semester_id IS NULL"

    execute <<~SQL.squish
      UPDATE #{table_name}
      SET course_offering_id = #{course_offering_id}
      FROM grade_import_batches
      WHERE #{table_name}.grade_import_batch_id = grade_import_batches.id
        AND #{table_name}.course_offering_id IS NULL
        AND #{table_name}.course_code = #{quoted_code}
        AND #{semester_condition}
    SQL
  end

  def update_grade_file_course_offering(grade_import_file_id, course_offering_id)
    return if grade_import_file_id.blank?
    return unless column_exists?(:grade_import_files, :course_offering_id)

    execute <<~SQL.squish
      UPDATE grade_import_files
      SET course_offering_id = #{course_offering_id}
      WHERE id = #{grade_import_file_id}
        AND course_offering_id IS NULL
    SQL
  end

  def course_title_for(parsed, file_name)
    known_title = KNOWN_COURSE_TITLES[[ parsed[:department_code], parsed[:course_number] ]]
    return known_title if known_title.present?

    title_from_file_name(parsed, file_name)
  end

  def title_from_file_name(parsed, file_name)
    token = file_name.to_s
    return if token.blank?

    normalized_code = [
      Regexp.escape(parsed[:department_code]),
      Regexp.escape(parsed[:course_number]),
      parsed[:section_number].present? ? Regexp.escape(parsed[:section_number]) : nil
    ].compact.join("[\\s_-]*")

    match = token.match(/#{normalized_code}__(.+?)(?:\.[^.]+)?\z/i)
    raw_title = match && match[1].to_s
    return if raw_title.blank?

    raw_title
      .tr("_", " ")
      .squeeze(" ")
      .strip
      .downcase
      .split
      .map(&:capitalize)
      .join(" ")
      .presence
  end

  def normalized_competency_sql(column)
    "regexp_replace(trim(regexp_replace(lower(replace(#{column}, '&', ' and ')), '[^a-z0-9]+', ' ', 'g')), ' +', ' ', 'g')"
  end

  def create_student_advisor_assignment_history
    return if table_exists?(:student_advisor_assignments)

    create_table :student_advisor_assignments do |t|
      t.bigint :student_id, null: false
      t.bigint :advisor_id
      t.date :starts_on, null: false
      t.date :ends_on
      t.boolean :primary_assignment, null: false, default: true
      t.bigint :assigned_by_id
      t.timestamps
    end

    add_index :student_advisor_assignments, :student_id
    add_index :student_advisor_assignments, :advisor_id
    add_index :student_advisor_assignments, :assigned_by_id
    add_index :student_advisor_assignments, [ :student_id, :starts_on ]
    add_index :student_advisor_assignments,
              [ :student_id ],
              unique: true,
              where: "primary_assignment = TRUE AND ends_on IS NULL",
              name: "idx_student_advisor_assignments_current_primary"

    add_foreign_key :student_advisor_assignments, :students, column: :student_id, primary_key: :student_id, on_delete: :cascade
    add_foreign_key :student_advisor_assignments, :advisors, column: :advisor_id, primary_key: :advisor_id, on_delete: :nullify
    add_foreign_key :student_advisor_assignments, :users, column: :assigned_by_id, on_delete: :nullify

    execute <<~SQL.squish
      INSERT INTO student_advisor_assignments
        (student_id, advisor_id, starts_on, ends_on, primary_assignment, created_at, updated_at)
      SELECT
        students.student_id,
        students.advisor_id,
        COALESCE(students.created_at::date, CURRENT_DATE),
        NULL,
        TRUE,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      FROM students
      WHERE students.advisor_id IS NOT NULL
    SQL
  end
end
