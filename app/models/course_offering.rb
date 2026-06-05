class CourseOffering < ApplicationRecord
  DEPARTMENT_NAMES = {
    "PHPM" => "Public Hlth Pol & Mgmt"
  }.freeze

  KNOWN_COURSE_TITLES = {
    [ "PHPM", "633" ] => "Health Law and Ethics"
  }.freeze

  SOURCE_CODE_PATTERN = /\A\s*([A-Z]{2,5})[\s_-]*(\d{3})(?:[\s_-]*(\d{3}))?\s*\z/i.freeze

  belongs_to :course
  belongs_to :program_semester, optional: true
  has_many :grade_import_files, dependent: :nullify
  has_many :grade_competency_evidences, dependent: :nullify
  has_many :grade_import_pending_rows, dependent: :nullify
  has_many :course_competency_targets, dependent: :destroy

  before_validation :normalize_section_number
  before_validation :derive_source_code

  validates :section_number, uniqueness: { scope: %i[course_id program_semester_id] }, allow_blank: true

  scope :active, -> { where(active: true, archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :ordered, -> { joins(course: :department).order("departments.code ASC", "courses.number ASC", :section_number) }

  def self.parse_source_code(value)
    match = SOURCE_CODE_PATTERN.match(value.to_s)
    return if match.blank?

    department_code = match[1].upcase
    course_number = match[2]
    section_number = match[3].presence

    {
      department_code: department_code,
      course_number: course_number,
      section_number: section_number,
      source_code: [ department_code, course_number, section_number ].compact.join("-")
    }
  end

  def self.find_or_create_from_code!(source_code, program_semester: nil, source_name: nil)
    parsed = parse_source_code(source_code)
    return if parsed.blank?

    department = Department.find_or_create_by!(code: parsed[:department_code]) do |record|
      record.name = department_name_for(parsed[:department_code])
    end

    course = Course.find_or_initialize_by(department: department, number: parsed[:course_number])
    course.title = course_title_for(parsed, source_name) if course.title.blank?
    course.active = true if course.active.nil?
    course.save!

    offering = find_or_initialize_by(
      course: course,
      program_semester: program_semester,
      section_number: parsed[:section_number]
    )
    offering.source_code = parsed[:source_code]
    offering.active = true if offering.active.nil?
    offering.save!
    offering
  end

  def self.department_name_for(code)
    DEPARTMENT_NAMES.fetch(code.to_s.upcase, code.to_s.upcase)
  end

  def self.course_title_for(parsed, source_name = nil)
    known_title = KNOWN_COURSE_TITLES[[ parsed[:department_code], parsed[:course_number] ]]
    return known_title if known_title.present?

    title_from_source_name(parsed, source_name)
  end

  def self.title_from_source_name(parsed, source_name)
    token = source_name.to_s
    return if token.blank?

    normalized_code = [
      Regexp.escape(parsed[:department_code]),
      Regexp.escape(parsed[:course_number]),
      parsed[:section_number].present? ? Regexp.escape(parsed[:section_number]) : nil
    ].compact.join("[\\s_-]*")

    match = token.match(/#{normalized_code}__(.+?)(?:\.[^.]+)?\z/i)
    raw_title = match && match[1].to_s
    return if raw_title.blank?

    raw_title.tr("_", " ").squeeze(" ").strip.titleize.presence
  end

  def display_code
    source_code.presence || [ course&.catalog_code, section_number ].compact_blank.join("-")
  end

  def course_code
    display_code
  end

  def display_name
    [ display_code, course&.title ].compact_blank.join(" ")
  end

  def archived?
    archived_at.present?
  end

  private

  def normalize_section_number
    self.section_number = section_number.to_s.strip.presence
  end

  def derive_source_code
    self.source_code = [ course&.catalog_code, section_number ].compact_blank.join("-") if source_code.blank?
  end
end
