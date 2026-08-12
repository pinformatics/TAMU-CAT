# Profile for student users, including survey responses and advisor
# relationships.
class Student < ApplicationRecord
  self.primary_key = :student_id

  attr_accessor :advisor_assignment_actor

  STATUSES = %w[active graduated withdrawn inactive archived].freeze
  LIFECYCLE_FILTERS = %w[current active graduated withdrawn inactive archived all].freeze
  UIN_FORMAT = /\A\d{9}\z/.freeze

  belongs_to :user, foreign_key: :student_id, primary_key: :id, inverse_of: :student_profile
  belongs_to :advisor, optional: true
  belongs_to :archived_by, class_name: "User", optional: true, inverse_of: :archived_students
  has_many :student_questions, dependent: :destroy
  has_many :questions, through: :student_questions
  has_many :feedbacks, foreign_key: :student_id
  has_many :survey_assignments, foreign_key: :student_id, primary_key: :student_id, dependent: :destroy
  has_many :advisor_assignments, class_name: "StudentAdvisorAssignment", foreign_key: :student_id, primary_key: :student_id, inverse_of: :student, dependent: :destroy
  has_one :current_advisor_assignment, -> { current }, class_name: "StudentAdvisorAssignment", foreign_key: :student_id, primary_key: :student_id, inverse_of: :student
  has_many :reconciled_grade_import_pending_rows, class_name: "GradeImportPendingRow", foreign_key: :matched_student_id, primary_key: :student_id, dependent: :nullify
  has_many :advisor_meeting_recaps, foreign_key: :student_id, primary_key: :student_id, dependent: :destroy

  delegate :email, :email=, :name, :name=, :avatar_url, :avatar_url=, to: :user

  before_validation :normalize_uin

  validates :uin, uniqueness: true, allow_nil: true
  validates :uin, presence: true, on: :profile_completion
  validates :uin, format: { with: UIN_FORMAT, message: "must be exactly 9 digits" }, allow_nil: true
  validates :status, inclusion: { in: STATUSES }
  validates :major, presence: true, on: :profile_completion
  validates :track_key, presence: true, on: :profile_completion
  validates :track_key,
            inclusion: { in: ->(_student) { ProgramTrack.keys } },
            allow_blank: true,
            on: :profile_completion
  # Program year is stored as a cohort/graduation year (e.g., 2026, 2027).
  validates :program_year, presence: true, on: :profile_completion
  validates :program_year, numericality: { only_integer: true, greater_than_or_equal_to: 2026, less_than_or_equal_to: 3000 }, allow_nil: true

  after_commit :auto_assign_track_survey, if: -> { saved_change_to_track? || saved_change_to_program_year? }
  after_commit :reconcile_pending_grade_import_rows, on: [ :create, :update ], if: :should_reconcile_pending_grade_import_rows?
  after_commit :sync_advisor_assignment_history, on: [ :create, :update ], if: :should_sync_advisor_assignment_history?

  scope :current_records, -> { where(status: "active", archived_at: nil, graduated_at: nil) }
  scope :archived_records, -> { where(status: "archived").or(where.not(archived_at: nil)) }
  scope :graduated, -> { where(status: "graduated").or(where.not(graduated_at: nil)) }
  scope :with_lifecycle_filter, ->(value) {
    case normalize_lifecycle_filter(value)
    when "all"
      all
    when "current"
      current_records
    when "active"
      current_records
    when "archived"
      archived_records
    when "graduated"
      graduated
    else
      where(status: normalize_lifecycle_filter(value))
    end
  }

  def self.lifecycle_filter_options
    [
      [ "Current students", "current" ],
      [ "Active only", "active" ],
      [ "Graduated", "graduated" ],
      [ "Withdrawn", "withdrawn" ],
      [ "Inactive", "inactive" ],
      [ "Archived", "archived" ],
      [ "All students", "all" ]
    ]
  end

  def self.normalize_lifecycle_filter(value, default: "current")
    normalized = value.to_s.strip.downcase
    return default if normalized.blank?

    LIFECYCLE_FILTERS.include?(normalized) ? normalized : default
  end

  # Checks if the student has completed their profile setup
  #
  # @return [Boolean]
  def profile_complete?
    user.name.present? && uin.present? && major.present? && track_key.present? && program_year.present?
  end

  def current_record?
    status == "active" && archived_at.blank? && graduated_at.blank?
  end

  def archived?
    status == "archived" || archived_at.present?
  end

  def graduated?
    status == "graduated" || graduated_at.present?
  end

  def archive!(archived_by: nil, reason: nil, at: Time.current)
    update!(
      status: "archived",
      graduated_at: nil,
      archived_at: at,
      archived_by: archived_by,
      archive_reason: reason
    )
  end

  def graduate!(at: Time.current)
    update!(
      status: "graduated",
      graduated_at: at,
      archived_at: nil,
      archived_by: nil,
      archive_reason: nil
    )
  end

  def reactivate!
    update!(
      status: "active",
      graduated_at: nil,
      archived_at: nil,
      archived_by: nil,
      archive_reason: nil
    )
  end

  def mark_inactive!
    update!(
      status: "inactive",
      graduated_at: nil,
      archived_at: nil,
      archived_by: nil,
      archive_reason: nil
    )
  end

  def withdraw!
    update!(
      status: "withdrawn",
      graduated_at: nil,
      archived_at: nil,
      archived_by: nil,
      archive_reason: nil
    )
  end

  def lifecycle_label
    if archived?
      "Archived"
    elsif graduated?
      "Graduated"
    elsif status.present?
      status.titleize
    else
      "Active"
    end
  end

  # Backwards-compat: treat legacy class_of as program_year.
  # (The DB column may be removed, but some code paths/tests still call class_of.)
  def class_of
    program_year
  end

  def class_of=(value)
    self.program_year = value
  end

  # @return [String] the student's preferred full name
  def full_name
    user.full_name
  end

  # Database stores the canonical key (e.g., "residential").
  # Public API returns the display label (e.g., "Residential") for UI use.
  def track
    ProgramTrack.name_for_key(track_key) || self[:track].to_s.strip.presence&.titleize
  end

  # Returns the canonical key used for filtering and persistence.
  # @return [String, nil]
  def track_key
    ProgramTrack.canonical_key(self[:track]) || self[:track].to_s.strip.downcase.presence
  end

  # Accepts either a key ("residential") or label ("Residential") and stores
  # the canonical key in the DB.
  def track=(value)
    key = ProgramTrack.canonical_key(value)
    current_track = self[:track].to_s.strip

    if key.present? && ProgramTrack.canonical_key(current_track) == key
      return
    end

    if key.blank? && current_track == value.to_s.strip
      return
    end

    self[:track] = key.presence || value.to_s.strip.presence
  end

  # Compatibility shim for code that used the enum mapping.
  # @return [Hash{String=>String}] key => label
  def self.tracks
    ProgramTrack.tracks_hash
  end

  # Saves the student and any pending user changes.
  #
  # @return [Boolean]
  def save(*args, **kwargs, &block)
    user.save! if user&.changed?
    super(*args, **kwargs, &block)
  end

  # Saves the student and underlying user, raising on failure.
  #
  # @return [Boolean]
  def save!(*args, **kwargs, &block)
    user.save! if user&.changed?
    super(*args, **kwargs, &block)
  end

  private

  def normalize_uin
    digits = uin.to_s.gsub(/\D+/, "")
    self.uin = digits.presence
  end

  def auto_assign_track_survey
    SurveyAssignments::AutoAssigner.call(student: self)
  rescue StandardError => e
    Rails.logger.error("Track auto-assign failed for student #{student_id}: #{e.class}: #{e.message}")
  end

  def should_reconcile_pending_grade_import_rows?
    previous_changes.key?("student_id") || previous_changes.key?("uin")
  end

  def reconcile_pending_grade_import_rows
    GradeImports::PendingRowReconciler.call(student: self)
  rescue StandardError => e
    Rails.logger.error("Pending grade import reconciliation failed for student #{student_id}: #{e.class}: #{e.message}")
  end

  def should_sync_advisor_assignment_history?
    previous_changes.key?("advisor_id") || (previous_changes.key?("student_id") && advisor_id.present?)
  end

  def sync_advisor_assignment_history
    return unless defined?(StudentAdvisorAssignment) && StudentAdvisorAssignment.table_exists?

    previous_advisor_id = previous_changes.dig("advisor_id", 0)

    StudentAdvisorAssignment.record_advisor_change!(
      student: self,
      advisor_id: advisor_id,
      previous_advisor_id: previous_advisor_id,
      assigned_by: advisor_assignment_actor
    )
  rescue StandardError => e
    Rails.logger.error("Advisor assignment history sync failed for student #{student_id}: #{e.class}: #{e.message}")
  ensure
    self.advisor_assignment_actor = nil
  end
end
