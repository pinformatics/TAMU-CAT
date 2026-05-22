# db/seeds.rb
require "json"
require "yaml"
require "active_support/core_ext/numeric/time"
require "set"
require "active_record/tasks/database_tasks"
require "stringio"

_seed_original_stdout = $stdout
_seed_silence_stdout = Rails.env.test? || ENV["QUIET_SEEDS"].present?
$stdout = StringIO.new if _seed_silence_stdout
begin

puts "\n== Seeding =="

def ensure_schema_loaded!
  connection = ActiveRecord::Base.connection

  return if connection.data_source_exists?("users")

  puts "• Running migrations"
  ActiveRecord::Tasks::DatabaseTasks.migrate
  ActiveRecord::Base.connection_pool.disconnect!
  ActiveRecord::Base.establish_connection
rescue StandardError => e
  warn "Unable to load schema automatically: #{e.message}"
  raise
end

ensure_schema_loaded!

# Majors
if ActiveRecord::Base.connection.data_source_exists?("majors")
  Major.find_or_create_by!(name: "Health Administration")
end

# Program tracks
if ActiveRecord::Base.connection.data_source_exists?("program_tracks")
  ProgramTrack.seed_defaults!
end

# Program years
if ActiveRecord::Base.connection.data_source_exists?("program_years")
  ProgramYear.seed_defaults!

  # Keep seed environments deterministic: only the default cohort years.
  # (Admins can add more cohort years in production if needed.)
  if Rails.env.development? || Rails.env.test?
    allowed_years = ProgramYear::DEFAULT_YEARS.map { |attrs| attrs.fetch(:value) }
    ProgramYear.where.not(value: allowed_years).delete_all
  end
end

previous_queue_adapter = ActiveJob::Base.queue_adapter
seed_async_adapter = nil

unless Rails.env.test?
  # Use a dedicated async adapter during seeding so notification jobs run concurrently
  # while still flushing before the process exits.
  seed_async_adapter = ActiveJob::QueueAdapters::AsyncAdapter.new(min_threads: 2, max_threads: 4, idletime: 1.second)
  ActiveJob::Base.queue_adapter = seed_async_adapter
  at_exit do
    seed_async_adapter&.shutdown if seed_async_adapter.respond_to?(:shutdown)
    ActiveJob::Base.queue_adapter = previous_queue_adapter
  end
end

begin
  connection = ActiveRecord::Base.connection
  has_solid_cache = connection.data_source_exists?("solid_cache_entries")

  if has_solid_cache
    Rails.cache.clear
  else
    puts "• Skipping cache clear (solid_cache_entries table not present)"
  end
rescue ActiveRecord::StatementInvalid => e
  warn "• Skipping cache clear (cache schema not loaded yet): #{e.message}"
end

# Demo/test seed data (sample users + generated responses) is intentionally
# disabled in production unless explicitly enabled.
# - Default: enabled in non-production, disabled in production.
# - Override: set SEED_DEMO_DATA=1 (or true/yes) to enable even in production.
#             set SEED_DEMO_DATA=0 (or false/no) to force-disable.
seed_demo_data = !Rails.env.production?
if ENV.key?("SEED_DEMO_DATA")
  raw = ENV["SEED_DEMO_DATA"].to_s.strip.downcase
  seed_demo_data = %w[1 true yes y on].include?(raw)
end
puts "• Skipping demo/test seed data" unless seed_demo_data

admin_users = []
advisors = []
students = []
pending_student_ids = []
multi_semester_student_ids = []

seed_user = lambda do |email:, name:, role:, uid: nil, avatar_url: nil|
  role_value = User.normalize_role(role) || role.to_s
  user = User.find_or_initialize_by(email: email)
  user.name = name
  user.uid = uid.presence || user.uid.presence || email
  user.avatar_url = avatar_url if avatar_url.present?
  user.role = role_value
  user.save!
  user.send(:ensure_role_profile!)
  user
end

puts "• Ensuring core advisor accounts"
core_advisor_accounts = [
  { email: "sarah115@tamu.edu", name: "Jack Buckley" },
  { email: "probinson@tamu.edu", name: "Phillip Robinson" },
  { email: "cstebbins@tamu.edu", name: "Carla Stebbins" }
]

core_advisor_accounts.each do |attrs|
  seed_user.call(email: attrs[:email], name: attrs[:name], role: :advisor)
end

# Lookup table used by demo student seeding.
advisors_by_email = User.advisors.includes(:advisor_profile).index_by { |u| u.email.to_s.downcase }

# Remove demo-only advisor accounts that should not exist.
# Keep this non-destructive: only delete when there are no advisees.
if seed_demo_data && (Rails.env.development? || Rails.env.test?)
  clark_user = User.find_by(email: "advisor.clark@tamu.edu")
  clark_profile = clark_user&.advisor_profile
  if clark_profile
    if clark_profile.advisees.exists?
      warn "• Advisor Clark (advisor.clark@tamu.edu) still has advisees; skipping deletion"
    else
      clark_user.destroy!
      advisors_by_email.delete("advisor.clark@tamu.edu")
      puts "• Removed Advisor Clark (advisor.clark@tamu.edu)"
    end
  end
end

if seed_demo_data
  puts "• Creating administrative accounts"
  admin_accounts = [
    { email: "westerman@tamu.edu", name: "Megan Westerman" },
    { email: "ruoqiwei@tamu.edu", name: "Ruoqi Wei" },
    { email: "rainsuds@tamu.edu", name: "Tianlan Li" }
  ]

  admin_users = admin_accounts.map do |attrs|
    seed_user.call(email: attrs[:email], name: attrs[:name], role: :admin)
  end

  if admin_users.empty?
    admin_users << seed_user.call(email: "admin@tamu.edu", name: "MHA Admin", role: :admin)
  end

  puts "• Creating sample students"
  students_data_path = Rails.root.join("db", "data", "sample_students.yml")
  unless File.exist?(students_data_path)
    raise "Sample students data file not found: #{students_data_path}."
  end

  students_seed = Array(YAML.safe_load_file(students_data_path))
  students_with_metadata = students_seed.map do |attrs|
    data = attrs.is_a?(Hash) ? attrs : {}
    email = data.fetch("email")
    name = data.fetch("name")
    track = data.fetch("track")
    advisor_email = data.fetch("advisor_email")
    pending = data.fetch("pending", false)
    raw_program_year = data.fetch("program_year", 2027)
    program_year = raw_program_year.to_i <= 10 ? (raw_program_year.to_i == 2 ? 2026 : 2027) : raw_program_year.to_i
    multi_semester = if data.key?("multi_semester")
      data.fetch("multi_semester")
    else
      raw_program_year.to_i <= 10 ? raw_program_year.to_i == 2 : program_year.to_i == 2026
    end

    advisor_key = advisor_email.to_s.downcase
    advisor_user = advisors_by_email[advisor_key]

    unless advisor_user
      fallback_name = advisor_email.to_s.split("@", 2).first.to_s
      fallback_name = fallback_name.tr("._", "  ").split.map(&:capitalize).join(" ")
      fallback_name = advisor_email.to_s if fallback_name.blank?

      advisor_user = seed_user.call(email: advisor_email, name: fallback_name, role: :advisor)
      advisors_by_email[advisor_key] = advisor_user
    end

    user = seed_user.call(email: email, name: name, role: :student)
    profile = user.student_profile || Student.new(student_id: user.id)
    profile.assign_attributes(track: track, advisor: advisor_user.advisor_profile, program_year: program_year)
    # Bypass validations for seed data; first-login flow will collect required fields
    profile.save!(validate: false)

    { profile: profile, pending: pending, multi_semester: multi_semester }
  end

  students = students_with_metadata.map { |entry| entry[:profile] }
  pending_student_ids = students_with_metadata.select { |entry| entry[:pending] }.map { |entry| entry[:profile].student_id }
  multi_semester_student_ids = students_with_metadata.select { |entry| entry[:multi_semester] }.map { |entry| entry[:profile].student_id }

  # Backfill legacy seed values (1/2) to cohort years so re-running seeds fixes
  # existing dev/test databases.
  if Rails.env.development? || Rails.env.test?
    Student.where(program_year: 1).update_all(program_year: 2027)
    Student.where(program_year: 2).update_all(program_year: 2026)
  end

  high_performer_emails = %w[
    nova.mitchell25@tamu.edu
    emery.walsh24@tamu.edu
    kiara.hughes25@tamu.edu
  ]
  high_performers = students.select { |student| high_performer_emails.include?(student.user.email) }
  high_performer_ids = high_performers.map(&:student_id)
end

puts "• Loading program survey templates"
survey_template_path = Rails.root.join("db", "data", "program_surveys.yml")
unless File.exist?(survey_template_path)
  raise "Survey template data file not found: #{survey_template_path}. Please ensure the survey definitions are available."
end

template_data = YAML.safe_load_file(survey_template_path, aliases: true)
survey_templates = Array(template_data.fetch("surveys"))

preferred_seed_current_semester = "Spring 2026"
semester_names = survey_templates.map do |definition|
  definition.fetch("program_semester").to_s.strip.presence
end.compact.uniq
if semester_names.blank?
  semester_names = [Time.zone.now.strftime("%B %Y")]
end

# Only keep 2026 semesters in seed data.
semester_names = semester_names.select { |name| name.match?(/\b2026\b/) }

existing_current_semester = ProgramSemester.current_name.to_s.strip.presence
# Seed behavior: in non-production environments, prefer the newest semester so
# newly created accounts get the newest surveys assigned automatically.
target_current_semester = if Rails.env.production? && !seed_demo_data
  existing_current_semester ||
    semester_names.find { |name| name.casecmp?(preferred_seed_current_semester) } ||
    semester_names.last
else
  semester_names.find { |name| name.casecmp?("Spring 2026") } ||
    semester_names.last ||
    existing_current_semester
end

target_current_semester ||= semester_names.first

unless semester_names.include?(target_current_semester)
  semester_names << target_current_semester
  semester_names.uniq!
end

puts "• Syncing program semesters"
ProgramSemester.transaction do
  semester_names.each do |name|
    ProgramSemester.find_or_create_by!(name: name)
  end

  # Ensure Fall 2026 exists as an empty semester placeholder.
  ProgramSemester.find_or_create_by!(name: "Fall 2026")

  ProgramSemester.where.not(name: target_current_semester).update_all(current: false)
  ProgramSemester.find_or_create_by!(name: target_current_semester).update!(current: true)
end

if ActiveRecord::Base.connection.data_source_exists?("competency_target_levels")
  defaults_path = Rails.root.join("db", "data", "default_target_levels.yml")
  if File.exist?(defaults_path)
    puts "• Seeding default competency target levels"

    defaults = YAML.safe_load_file(defaults_path)
    semesters_to_seed = Array(defaults["semesters"]).map { |name| name.to_s.strip }.reject(&:blank?)
    program_years_to_seed = Array(defaults["program_years"]).map { |val| val.to_i }.uniq
    track_defaults = defaults["tracks"].is_a?(Hash) ? defaults["tracks"] : {}

    competency_titles = Reports::DataAggregator::COMPETENCY_TITLES
    now = Time.current
    rows = []

    semesters_to_seed.each do |semester_name|
      program_semester = ProgramSemester.find_or_create_by!(name: semester_name)

      track_defaults.each do |track_name, track_config|
        levels = Array(track_config.is_a?(Hash) ? track_config["levels"] : nil).map(&:to_i)
        if levels.size != competency_titles.size
          warn "• Skipping target levels for #{track_name} (#{semester_name}): expected #{competency_titles.size} levels, got #{levels.size}"
          next
        end

        program_years_to_seed.each do |program_year|
          class_of = if program_year <= 10
            program_year == 2 ? 2026 : 2027
          else
            program_year
          end

          competency_titles.each_with_index do |title, idx|
            rows << {
              program_semester_id: program_semester.id,
              track: track_name,
              class_of: class_of,
              competency_title: title,
              target_level: levels[idx],
              created_at: now,
              updated_at: now
            }
          end
        end
      end
    end

    if rows.any?
      CompetencyTargetLevel.upsert_all(rows, unique_by: :index_competency_targets_unique)
    end
  end
end

answer_options_for = lambda do |options|
  return nil if options.blank?

  normalized = Array(options).filter_map do |entry|
    case entry
    when String
      entry.to_s.strip.presence
    when Array
      next if entry.empty?

      label = entry[0].to_s.strip
      value = entry[1].to_s.strip
      next if label.blank? || value.blank?

      [label, value]
    when Hash
      label = (entry["label"] || entry[:label]).to_s.strip
      value = (entry["value"] || entry[:value] || label).to_s.strip
      next if label.blank? || value.blank?

      requires_text = entry.key?("requires_text") || entry.key?(:requires_text) ? !!(entry["requires_text"] || entry[:requires_text]) : nil
      requires_text = entry.key?("other_text") || entry.key?(:other_text) ? !!(entry["other_text"] || entry[:other_text]) : requires_text
      requires_text = entry.key?("other") || entry.key?(:other) ? !!(entry["other"] || entry[:other]) : requires_text

      definition = { "label" => label, "value" => value }
      definition["requires_text"] = true if requires_text
      definition
    else
      entry.to_s.strip.presence
    end
  end

  normalized.to_json
end

created_surveys = []

legend_supported = ActiveRecord::Base.connection.data_source_exists?("survey_legends")
question_target_level_supported = ActiveRecord::Base.connection.column_exists?(:questions, :program_target_level)
sub_questions_supported = ActiveRecord::Base.connection.column_exists?(:questions, :parent_question_id) &&
                          ActiveRecord::Base.connection.column_exists?(:questions, :sub_question_order)

survey_templates.each do |definition|
  title = definition.fetch("title")
  semester = definition.fetch("program_semester").to_s.strip
  puts "   • Ensuring survey: #{title} (#{semester})"

  program_semester = ProgramSemester.find_or_create_by!(name: semester)

  Survey.transaction do
    survey = Survey.find_or_initialize_by(title: title, program_semester: program_semester)
    survey.creator ||= admin_users.first || User.admins.first
    survey.description = definition["description"]
    survey.is_active = definition.fetch("is_active", true)

    if legend_supported
      legend_definition = definition["legend"].presence
      if legend_definition.present?
        legend_record = survey.legend || survey.build_legend
        legend_record.title = legend_definition["title"].to_s.strip.presence
        legend_record.body = legend_definition.fetch("body", "").to_s
      else
        survey.legend&.mark_for_destruction
      end
    end

    if survey.persisted?
      stale_category_ids = survey.categories.ids
      stale_question_ids = survey.questions.ids

      if stale_category_ids.any?
        survey.feedbacks.where(category_id: stale_category_ids).delete_all
      end

      if stale_question_ids.any?
        survey.feedbacks.where(question_id: stale_question_ids).delete_all
      end

      survey.categories.destroy_all
      survey.categories.reset
    else
      survey.categories.reset
    end

    sections_supported = SurveySection.table_exists?
    if sections_supported
      survey.sections.destroy_all if survey.persisted?
      survey.sections.reset
    end

    question_feedback_supported = Question.column_names.include?("has_feedback")

    categories = Array(definition.fetch("categories", [])) + Array(definition["extra_categories"])
    section_assignments = sections_supported ? {} : nil
    categories.each do |category_definition|
      category = survey.categories.build(
        name: category_definition.fetch("name"),
        description: category_definition["description"]
      )

      section_definition = category_definition["section"]
      section_title = section_definition&.fetch("title", nil).to_s.strip
      is_mha_competency_section = section_title.present? && section_title.casecmp?(SurveySection::MHA_COMPETENCY_SECTION_TITLE)
      if sections_supported && section_definition.present?
        if section_title.present?
          section_assignments[category] = {
            title: section_title,
            description: section_definition["description"],
            position: section_definition["position"]
          }
        end
      end

      Array(category_definition.fetch("questions", [])).each do |question_definition|
        tooltip_value = question_definition["tooltip"].to_s.strip
        if tooltip_value.blank? && is_mha_competency_section && question_definition["type"].to_s == "multiple_choice"
          tooltip_value = question_definition["description"].to_s.strip
        end

        build_attrs = {
          question_text: question_definition.fetch("text"),
          description: question_definition["description"],
          tooltip_text: tooltip_value.presence,
          question_order: question_definition.fetch("order"),
          question_type: question_definition.fetch("type"),
          prompt_format: question_definition["prompt_format"],
          integer_min: question_definition["integer_min"],
          integer_max: question_definition["integer_max"],
          is_required: question_definition.fetch("required", false),
          has_evidence_field: question_definition.fetch("has_evidence_field", false),
          answer_options: answer_options_for.call(question_definition["options"])
        }

        if question_feedback_supported
          build_attrs[:has_feedback] = question_definition.fetch("has_feedback", is_mha_competency_section)
        end

        if question_target_level_supported && is_mha_competency_section && %w[multiple_choice dropdown].include?(question_definition["type"].to_s)
          raw_target_level = question_definition["target_level"].presence || question_definition["program_target_level"].presence || 3
          build_attrs[:program_target_level] = raw_target_level.to_i
        end

        parent_question = category.questions.build(build_attrs)

        if sub_questions_supported
          Array(question_definition["sub_questions"]).each do |sub_definition|
          sub_tooltip_value = sub_definition["tooltip"].to_s.strip
          if sub_tooltip_value.blank? && is_mha_competency_section && sub_definition["type"].to_s == "multiple_choice"
            sub_tooltip_value = sub_definition["description"].to_s.strip
          end

          sub_attrs = {
            question_text: sub_definition.fetch("text"),
            description: sub_definition["description"],
            tooltip_text: sub_tooltip_value.presence,
            question_order: parent_question.question_order,
            sub_question_order: sub_definition.fetch("order", 0),
            question_type: sub_definition.fetch("type"),
            prompt_format: sub_definition["prompt_format"],
            integer_min: sub_definition["integer_min"],
            integer_max: sub_definition["integer_max"],
            is_required: sub_definition.fetch("required", false),
            has_evidence_field: sub_definition.fetch("has_evidence_field", false),
            answer_options: answer_options_for.call(sub_definition["options"]),
            parent_question: parent_question
          }

          if question_feedback_supported
            sub_attrs[:has_feedback] = sub_definition.fetch("has_feedback", false)
          end

          if question_target_level_supported && is_mha_competency_section && %w[multiple_choice dropdown].include?(sub_definition["type"].to_s)
            raw_target_level = sub_definition["target_level"].presence || sub_definition["program_target_level"].presence || 3
            sub_attrs[:program_target_level] = raw_target_level.to_i
          end

          category.questions.build(sub_attrs)
          end
        end
      end
    end

    survey.save!

    if sub_questions_supported
      # When building nested questions in-memory, sub-questions may be saved before the
      # parent question has an ID, leaving parent_question_id unset. Repair those links
      # after the survey save so sub-questions are correctly attached.
      survey.categories.each do |category|
        category.questions.each do |question|
          parent = question.parent_question
          next unless parent
          next if question.parent_question_id.present?
          next unless parent.id

          question.update!(parent_question_id: parent.id)
        end
      end
    end

    if sections_supported && section_assignments.present?
      section_records = {}
      ordered_keys = []

      section_assignments.each_value do |attrs|
        title = attrs[:title]
        next if title.blank?
        next if section_records.key?(title)

        ordered_keys << title
        section_records[title] = survey.sections.create!(
          title: title,
          description: attrs[:description],
          position: attrs[:position].presence || ordered_keys.size
        )
      end

      section_assignments.each do |category, attrs|
        section = section_records[attrs[:title]]
        next unless section

        category.update!(section: section)
      end
    end

    tracks = Array(definition.fetch("tracks", [])).map(&:to_s)
    survey.assign_tracks!(tracks)

    raw_available_from = definition["available_from"].to_s.strip
    raw_available_until = definition["available_until"].to_s.strip

    if raw_available_from.present?
      begin
        survey.available_from = Time.zone.parse(raw_available_from)
      rescue StandardError
        # Ignore invalid available_from values.
      end
    end

    if raw_available_until.present?
      begin
        parsed_until = Time.zone.parse(raw_available_until)
        survey.available_until = if raw_available_until.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          parsed_until&.end_of_day
        else
          parsed_until
        end
      rescue StandardError
        # Ignore invalid available_until values.
      end
    end

    survey.save! if survey.changed?

    created_surveys << survey
  end
end

if ActiveRecord::Base.connection.data_source_exists?("survey_offerings")
  puts "• Syncing survey offerings (program/cohort/stage schedule)"

  stage_surveys_by_title = {
    "RMHA Initial Competency Survey" => { track: "Residential", stage: "initial" },
    "RMHA Mid-point Competency Survey" => { track: "Residential", stage: "midpoint" },
    "RMHA Final Competency Survey" => { track: "Residential", stage: "final" },
    "EMHA Mid-point Competency Survey" => { track: "Executive", stage: "midpoint" },
    "EMHA Final Competency Survey" => { track: "Executive", stage: "final" }
  }

  schedule_rows = [
    # RMHA
    { title: "RMHA Initial Competency Survey", class_of: 2027, portfolio_due_date: "2026-01-16", review_start: "2026-01-20", review_end: "2026-02-16" },
    { title: "RMHA Mid-point Competency Survey", class_of: 2026, portfolio_due_date: "2026-01-16", review_start: nil, review_end: nil },
    { title: "RMHA Final Competency Survey", class_of: 2026, portfolio_due_date: "2026-03-20", review_start: "2026-03-20", review_end: "2026-04-17" },

    # EMHA
    { title: "EMHA Mid-point Competency Survey", class_of: 2027, portfolio_due_date: "2026-05-31", review_start: "2026-06-01", review_end: "2026-08-04" },
    { title: "EMHA Final Competency Survey", class_of: 2026, portfolio_due_date: "2026-03-20", review_start: "2026-03-21", review_end: "2026-04-17" }
  ]

  schedule_rows.each do |row|
    config = stage_surveys_by_title[row[:title]]
    next unless config

    survey = Survey.find_by(title: row[:title])
    unless survey
      warn "• Skipping offering for #{row[:title]} (survey not found)"
      next
    end

    offering_lookup = {
      survey: survey,
      track: config[:track],
      class_of: row[:class_of],
      stage: config[:stage]
    }
    if SurveyOffering.column_names.include?("assignment_group")
      offering_lookup[:assignment_group] = nil
    end

    offering = SurveyOffering.find_or_initialize_by(offering_lookup)

    availability_start = Time.zone.parse("2026-01-05 09:00")
    offering.available_from = availability_start if offering.respond_to?(:available_from)

    if row[:portfolio_due_date].present?
      raw_due = row[:portfolio_due_date].to_s.strip
      parsed = Time.zone.parse(raw_due)
      due_at = if raw_due.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        parsed&.change(hour: 23, min: 59)
      else
        parsed
      end

      offering.portfolio_due_date = due_at
      offering.available_until = due_at if offering.respond_to?(:available_until)
    else
      offering.portfolio_due_date = nil
      if offering.respond_to?(:available_until)
        raw_review_end = row[:review_end].to_s.strip
        parsed_review_end = raw_review_end.present? ? Time.zone.parse(raw_review_end) : nil
        offering.available_until = parsed_review_end&.change(hour: 23, min: 59)
      end
    end

    offering.review_meetings_start = row[:review_start].present? ? Date.parse(row[:review_start].to_s) : nil
    offering.review_meetings_end = row[:review_end].present? ? Date.parse(row[:review_end].to_s) : nil
    offering.active = true if offering.active.nil?
    offering.save!
  end
end

puts "• Assigning surveys to each student"
response_rng = Random.new(20_251_110)

sample_numeric = lambda do |min:, max:|
  value = response_rng.rand(min..max)
  # Keep one decimal place for readability
  format("%.1f", value.round(1))
end

sample_timestamp = lambda do
  # Spread responses over roughly the last 18 months for chart trends
  months_ago = response_rng.rand(0..18)
  days_offset = response_rng.rand(0..28)
  Time.zone.now - months_ago.months - days_offset.days
end

response_timestamp_for = lambda do |survey|
  available_from = survey.available_from
  available_until = survey.available_until

  unless available_from.present? && available_until.present?
    next sample_timestamp.call
  end

  window_start = available_from + 1.day
  window_end = available_until - 6.hours

  if window_end <= window_start
    next [ available_from + 1.hour, available_until - 1.hour, Time.current ].compact.min
  end

  Time.zone.at(response_rng.rand(window_start.to_i..window_end.to_i))
end

completion_timestamp_for = lambda do |survey:, latest_response_timestamp:|
  timestamp = latest_response_timestamp || response_timestamp_for.call(survey)
  available_from = survey.available_from
  available_until = survey.available_until

  return timestamp unless available_until.present?

  latest_allowed = available_until - 1.hour
  earliest_allowed = available_from.present? ? (available_from + 2.hours) : nil
  timestamp = [ timestamp, latest_allowed ].compact.min
  timestamp = [ timestamp, earliest_allowed ].compact.max if earliest_allowed.present?
  timestamp
end

assigned_timestamp_for = lambda do |survey:, completion_timestamp:|
  available_from = survey.available_from
  earliest_allowed = available_from.present? ? [ available_from, completion_timestamp - 10.days ].max : completion_timestamp - 10.days
  latest_allowed = completion_timestamp - 1.day

  if latest_allowed <= earliest_allowed
    [ earliest_allowed, completion_timestamp - 1.hour ].min
  else
    Time.zone.at(response_rng.rand(earliest_allowed.to_i..latest_allowed.to_i))
  end
end

sample_text = lambda do |question|
  base = case question.question_type
         when "short_answer"
           "Reflection on #{question.question_text.downcase}".squish
         else
           "Response for #{question.question_text.downcase}".squish
         end
  suffix = ["highlighted progress", "noted opportunities", "summarized outcomes", "flagged next steps", "shared learnings"].sample(random: response_rng)
  "#{base} — #{suffix}."
end

drive_links = %w[
  https://sites.google.com/view/mha-portfolio-avery
  https://sites.google.com/view/mha-portfolio-emery
  https://sites.google.com/view/mha-portfolio-kiara
]

choice_values_for = lambda do |question|
  raw = question.answer_options.presence || "[]"
  parsed = JSON.parse(raw)
  Array(parsed).filter_map do |entry|
    case entry
    when String
      entry.to_s.strip.presence
    when Hash
      (entry["value"] || entry[:value] || entry["label"] || entry[:label]).to_s.strip.presence
    when Array
      next if entry.empty?

      (entry[1] || entry[0]).to_s.strip.presence
    else
      entry.to_s.strip.presence
    end
  end.uniq
rescue JSON::ParserError
  []
end

competency_titles = Reports::DataAggregator::COMPETENCY_TITLES
competency_title_lookup = competency_titles.map { |title| title.to_s.strip }.to_set

competency_rating_value = lambda do |high_performer:|
  pool = if high_performer
           [4, 4, 5, 5, 5]
         else
           [2, 3, 3, 4, 4, 5]
         end
  pool.sample(random: response_rng).to_s
end

students.each do |student|
  track_key = student.track.presence || ProgramTrack.canonical_key(student.read_attribute(:track))
  track_key = track_key.to_s.strip
  next if track_key.blank?

  track_label = ProgramTrack.name_for_key(track_key) || student.read_attribute(:track).to_s.strip
  pending_student = pending_student_ids.include?(student.student_id)
  program_year_value = student.program_year.to_i

  year_1 = [1, 2027].include?(program_year_value)
  year_2 = [2, 2026].include?(program_year_value)

  surveys_to_seed = if SurveyOffering.data_source_ready? && SurveyOffering.active.exists?
    SurveyOffering.for_student(track_key: track_key, class_of: student.program_year)
      .includes(:survey)
      .map(&:survey)
      .compact
      .uniq
  else
    created_surveys.select do |survey|
      survey.program_semester&.name.to_s.strip.casecmp?(target_current_semester.to_s.strip) &&
        survey.track_list.any? { |track| track.to_s.strip.casecmp?(track_label.to_s.strip) }
    end
  end

  if (multi_semester_student_ids.include?(student.student_id) || year_2) &&
     !(SurveyOffering.data_source_ready? && SurveyOffering.active.exists?)
    multi_semesters = ["Spring 2026"].freeze
    extra_surveys = created_surveys.select do |survey|
      multi_semesters.include?(survey.program_semester.name.to_s.strip) &&
        survey.track_list.any? { |track| track.to_s.strip.casecmp?(track_label.to_s.strip) }
    end
    surveys_to_seed = (surveys_to_seed + extra_surveys).uniq
  end

  surveys_to_seed.each do |survey|
    latest_response_timestamp = nil

    unless pending_student
      survey.questions.order(:question_order).each do |question|
        record = StudentQuestion.find_or_initialize_by(student_id: student.student_id, question_id: question.id)

        response_roll = response_rng.rand
        advisor_profile = student.advisor
        question_label = question.question_text.to_s.strip
        is_competency_question = competency_title_lookup.include?(question_label)
        high_performer = high_performer_ids.include?(student.student_id)

        # Ensure competency metrics always capture a student self-rating entry
        record.advisor_id = if is_competency_question
                              nil
                            else
                              case response_roll
                              when 0.0..0.20
                                nil
                              when 0.20..0.65
                                nil
                              else
                                advisor_profile&.advisor_id
                              end
                            end

        response_value = case question.question_type
                         when "evidence"
                           high_performer ? drive_links.first : drive_links.sample(random: response_rng)
                         when "integer"
                           min = question.integer_min.presence || 0
                           max = question.integer_max.presence || [min, 10].max
                           chosen = if high_performer
                             response_rng.rand([max - 2, min].max..max)
                           else
                             response_rng.rand(min..max)
                           end
                           chosen.to_s
                         when "multiple_choice"
                           options = choice_values_for.call(question)
                           other_pair = question.answer_option_pairs.find { |(label, _value)| label.to_s.strip.downcase.start_with?("other") }
                           other_value = other_pair ? other_pair[1].to_s : "Other"

                           if is_competency_question
                             rating_value = competency_rating_value.call(high_performer: high_performer)
                             options.include?(rating_value) ? rating_value : (options.sample(random: response_rng).presence || rating_value || "3")
                           else
                             preferred = high_performer ? "Yes" : nil
                             selection = options.sample(random: response_rng).presence
                             fallback = preferred && options.include?(preferred) ? preferred : selection
                             fallback.presence || preferred || options.first || "Yes"
                           end
                         when "dropdown"
                           options = choice_values_for.call(question)
                           other_pair = question.answer_option_pairs.find { |(label, _value)| label.to_s.strip.downcase.start_with?("other") }
                           other_value = other_pair ? other_pair[1].to_s : "Other"

                           if is_competency_question
                             rating_value = competency_rating_value.call(high_performer: high_performer)
                             options.include?(rating_value) ? rating_value : (options.sample(random: response_rng).presence || rating_value || "3")
                           else
                             options.sample(random: response_rng).presence || options.first
                           end
                         when "short_answer"
                           if is_competency_question
                             competency_rating_value.call(high_performer: high_performer)
                           else
                             high_performer ? "Delivered an exceptional outcome that exceeded expectations." : sample_text.call(question)
                           end
                         else
                           high_performer ? "Completed with distinction." : sample_text.call(question)
                         end

        if %w[multiple_choice dropdown].include?(question.question_type)
          serialized = response_value.to_s
          option_pairs = question.answer_option_pairs
          other_pair = option_pairs.find { |(label, _value)| label.to_s.strip.downcase.start_with?("other") }
          other_value = other_pair ? other_pair[1].to_s : "Other"
          other_selected = serialized == other_value || serialized.casecmp?("Other") || serialized.strip.downcase.start_with?("other")

          if other_selected
            other_label = other_pair ? other_pair[0].to_s.downcase : ""
            question_text = question.question_text.to_s.downcase

            other_text = if other_label.include?("work schedule") || (question_text.include?("work") && question_text.include?("hours"))
              "My schedule varies week-to-week; I can usually adjust shifts with some notice."
            else
              sample_text.call(question)
            end

            answer_for_storage = other_pair ? other_value : (serialized.presence || "Other")
            response_value = { "answer" => answer_for_storage, "text" => other_text.to_s }.to_json
          end
        end

        record.advisor_id ||= advisor_profile&.advisor_id if high_performer && !is_competency_question

        # Introduce the occasional "not assessed" entry for advisors (skip top performers)
        if !is_competency_question && record.advisor_id.present? && response_roll < 0.28 && !high_performer_ids.include?(student.student_id)
          response_value = nil
        end

        # Spread timestamps so reports show multiple cohorts/timepoints
        timestamp = response_timestamp_for.call(survey)
        record.created_at ||= timestamp
        record.updated_at = timestamp
        latest_response_timestamp = [ latest_response_timestamp, timestamp ].compact.max

        record.response_value = response_value
        record.save!
      end

      puts "   • Prepared #{survey.questions.count} questions for #{student.user.name} (#{track_label})"
      puts "     ↳ High performer calibration applied" if high_performer_ids.include?(student.student_id)
      puts "     ↳ Auto-assign will sync survey tasks from offerings"

      # Seed completion history for most Year-1 students on the Spring 2026 survey.
      # This helps exercise UI states that depend on completed assignments.
      if survey.program_semester&.name.to_s.strip.casecmp?("Spring 2026") && year_1
        incomplete_seed_email = "zoe.elliott24@tamu.edu"
        completion_timestamp = completion_timestamp_for.call(
          survey: survey,
          latest_response_timestamp: latest_response_timestamp
        )
        assigned_timestamp = assigned_timestamp_for.call(
          survey: survey,
          completion_timestamp: completion_timestamp
        )

        assignment = SurveyAssignment.find_or_create_by!(student_id: student.student_id, survey_id: survey.id) do |record|
          record.advisor_id = student.advisor_id
          record.assigned_at = assigned_timestamp
          record.available_from = survey.available_from
          record.available_until = survey.available_until
        end

        assignment.update!(advisor_id: student.advisor_id) if assignment.advisor_id.blank? && student.advisor_id.present?
        assignment.update!(assigned_at: assigned_timestamp) if assignment.assigned_at.blank? || assignment.assigned_at > completion_timestamp
        assignment.update!(available_from: survey.available_from) if assignment.available_from.blank? && survey.available_from.present?
        assignment.update!(available_until: survey.available_until) if assignment.available_until.blank? && survey.available_until.present?
        assignment.update!(completed_at: nil) if student.user.email.to_s.downcase == incomplete_seed_email

        unless student.user.email.to_s.downcase == incomplete_seed_email
          assignment.mark_completed!(completion_timestamp)

          SurveyResponseVersion.capture_current!(
            student: student,
            survey: survey,
            assignment: assignment,
            actor_user: student.user,
            event: :submitted,
            skip_if_unchanged: true
          )
        end
      end

      # Seed Year-2 students with multi-semester completions so confidential
      # notes history and version navigation have realistic data.
      if year_2
        completion_semesters = ["Spring 2026"].freeze
        if completion_semesters.include?(survey.program_semester&.name.to_s.strip)
          completion_timestamp = completion_timestamp_for.call(
            survey: survey,
            latest_response_timestamp: latest_response_timestamp
          )
          assigned_timestamp = assigned_timestamp_for.call(
            survey: survey,
            completion_timestamp: completion_timestamp
          )

          assignment = SurveyAssignment.find_or_create_by!(student_id: student.student_id, survey_id: survey.id) do |record|
            record.advisor_id = student.advisor_id
            record.assigned_at = assigned_timestamp
            record.available_from = survey.available_from
            record.available_until = survey.available_until
          end

          assignment.update!(advisor_id: student.advisor_id) if assignment.advisor_id.blank? && student.advisor_id.present?
          assignment.update!(assigned_at: assigned_timestamp) if assignment.assigned_at.blank? || assignment.assigned_at > completion_timestamp
          assignment.update!(available_from: survey.available_from) if assignment.available_from.blank? && survey.available_from.present?
          assignment.update!(available_until: survey.available_until) if assignment.available_until.blank? && survey.available_until.present?
          assignment.mark_completed!(completion_timestamp)

          SurveyResponseVersion.capture_current!(
            student: student,
            survey: survey,
            assignment: assignment,
            actor_user: student.user,
            event: :submitted,
            skip_if_unchanged: true
          )
        end
      end
    else
      puts "   • Assigned #{survey.title} to #{student.user.name} (#{track_label}) — awaiting completion"
    end

  end

  # Ensure every student gets assignments immediately from offerings.
  SurveyAssignments::AutoAssigner.call(student: student, track: track_key, class_of: student.program_year)
end

puts "   • Generated sample ratings for #{StudentQuestion.count} question responses"

puts "🎉 Seed data finished!"

ensure
  $stdout = _seed_original_stdout if _seed_silence_stdout
end
