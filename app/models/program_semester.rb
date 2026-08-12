# Tracks program semesters (e.g., "Fall 2025") and identifies which one is current.
class ProgramSemester < ApplicationRecord
  STATUSES = %w[planned current closed archived].freeze
  DEFAULT_CURRENT_NAME = "Fall 2025".freeze
  ORDER_SQL = <<~SQL.squish.freeze
    COALESCE(
      starts_on,
      make_date(
        COALESCE(NULLIF(substring(program_semesters.name from '[0-9]{4}'), '')::integer, 9999),
        CASE LOWER(SPLIT_PART(program_semesters.name, ' ', 1))
          WHEN 'winter' THEN 1
          WHEN 'spring' THEN 1
          WHEN 'summer' THEN 5
          WHEN 'fall' THEN 8
          ELSE 12
        END,
        1
      )
    ) ASC,
    program_semesters.id ASC
  SQL

  has_many :surveys, dependent: :destroy
  has_many :grade_import_batches, dependent: :nullify
  has_many :competency_target_levels, dependent: :destroy
  has_many :course_offerings, dependent: :nullify
  has_one :course_grade_release_date, dependent: :destroy
  has_many :advisor_meeting_recaps, dependent: :destroy

  before_validation :normalize_name
  before_validation :sync_status_from_current_flag
  before_validation :derive_dates_from_name
  after_commit :ensure_single_current!, if: -> { saved_change_to_current? && current? }
  after_commit :ensure_single_status_current!, if: -> { saved_change_to_status? && status == "current" }
  after_destroy :assign_fallback_current!

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :status, inclusion: { in: STATUSES }

  scope :ordered, -> { order(Arel.sql(ORDER_SQL)) }
  scope :operational, -> { where.not(status: "archived").where(archived_at: nil) }
  scope :archived_records, -> { where(status: "archived").or(where.not(archived_at: nil)) }

  # @return [ProgramSemester, nil]
  def self.current
    find_by(current: true) || find_by_name_case_insensitive(DEFAULT_CURRENT_NAME) || ordered.to_a.last
  end

  # @return [String, nil]
  def self.current_name
    current&.name
  end

  def self.find_by_name_case_insensitive(value)
    return if value.blank?

    where("LOWER(name) = ?", value.to_s.downcase).first
  end

  def is_current?
    current?
  end

  def archived?
    status == "archived" || archived_at.present?
  end

  def closed?
    status == "closed" || closed_at.present?
  end

  def active_for_operations?
    !archived?
  end

  private

  def normalize_name
    self.name = name.to_s.strip.squeeze(" ")
    return if name.blank?

    tokens = name.split(/\s+/)
    self.name = tokens.map.with_index do |token, index|
      if token.match?(/^\d+$/)
        token
      elsif index.zero?
        token.capitalize
      else
        token
      end
    end.join(" ")
  end

  def derive_dates_from_name
    return if name.blank?
    return if starts_on.present? && ends_on.present?

    match = name.match(/\A(\w+)\s+(\d{4})\z/)
    return unless match

    term = match[1].downcase
    year = match[2].to_i
    range = case term
    when "winter"
      [ Date.new(year, 1, 1), Date.new(year, 1, 31) ]
    when "spring"
      [ Date.new(year, 1, 1), Date.new(year, 4, 30) ]
    when "summer"
      [ Date.new(year, 5, 1), Date.new(year, 7, 31) ]
    when "fall"
      [ Date.new(year, 8, 1), Date.new(year, 12, 31) ]
    end
    return unless range

    self.starts_on ||= range.first
    self.ends_on ||= range.last
  end

  def sync_status_from_current_flag
    self.status = "current" if current? && (status.blank? || will_save_change_to_current?)
    self.current = true if status == "current"
  end

  def ensure_single_current!
    ProgramSemester.where.not(id: id).update_all(current: false)
  end

  def ensure_single_status_current!
    ProgramSemester.where.not(id: id).where(current: true).update_all(current: false, status: "closed")
    ProgramSemester.where.not(id: id).where(status: "current").update_all(status: "closed")
  end

  def assign_fallback_current!
    return if ProgramSemester.where(current: true).exists?

    fallback = ProgramSemester.ordered.to_a.last
    fallback&.update_column(:current, true)
  end
end
