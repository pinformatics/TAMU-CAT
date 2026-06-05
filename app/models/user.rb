# Application-level user record that authenticates via Google OAuth and ties to
# role-specific profiles (student, advisor, admin). A user has exactly one
# primary role and lazily materializes the corresponding profile record.
class User < ApplicationRecord
  self.primary_key = :id

  devise :omniauthable, :timeoutable, omniauth_providers: [ :google_oauth2 ]

  enum :role, { student: "student", advisor: "advisor", admin: "admin" }, prefix: true

  has_one :admin_profile, class_name: "Admin", foreign_key: :admin_id, inverse_of: :user, dependent: :destroy
  has_one :advisor_profile, class_name: "Advisor", foreign_key: :advisor_id, inverse_of: :user, dependent: :destroy
  has_one :student_profile, class_name: "Student", foreign_key: :student_id, inverse_of: :user, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :archived_students, class_name: "Student", foreign_key: :archived_by_id, inverse_of: :archived_by, dependent: :nullify
  has_many :student_advisor_assignments_made, class_name: "StudentAdvisorAssignment", foreign_key: :assigned_by_id, inverse_of: :assigned_by, dependent: :nullify
  has_many :created_surveys, class_name: "Survey", foreign_key: :created_by_id, inverse_of: :creator, dependent: :nullify
  has_many :survey_change_logs, foreign_key: :admin_id, inverse_of: :admin, dependent: :nullify

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
  validates :role, presence: true, inclusion: { in: roles.values }
  validates :text_scale_percent, numericality: { only_integer: true, greater_than_or_equal_to: 100, less_than_or_equal_to: 200 }, allow_nil: true

  after_commit :ensure_role_profile!, on: [ :create, :update ]
  after_commit :reconcile_pending_grade_import_rows_for_student, on: [ :create, :update ], if: :should_reconcile_pending_grade_import_rows_for_student?

  scope :students, -> { where(role: roles[:student]) }
  scope :advisors, -> { where(role: roles[:advisor]) }
  scope :admins, -> { where(role: roles[:admin]) }

  # Finds or creates a user based on Google OAuth data and ensures the proper
  # role profile exists.
  #
  # @param email [String]
  # @param name [String]
  # @param uid [String]
  # @param avatar_url [String]
  # @param role [String, Symbol, nil] optional incoming role hint
  # @return [User]
  def self.from_google(email:, name:, uid:, avatar_url:, role: nil)
    user = find_or_initialize_by(email: email)
    user.uid = uid if uid.present?
    user.name = name if name.present?
    user.avatar_url = avatar_url if avatar_url.present?

    normalized_role = normalize_role(role) || user.role || roles[:student]
    user.role = normalized_role

    user.save!
    user.send(:ensure_role_profile!)
    user
  end

  # Normalizes a loosely specified role value into one of the persisted role
  # strings.
  #
  # @param role [String, Symbol, nil]
  # @return [String, nil]
  def self.normalize_role(role)
    return nil if role.blank?

    role_string = role.to_s.downcase
    roles.find { |_key, value| value == role_string }&.last
  end

  # @return [String] the user's preferred full name
  def full_name
    name
  end

  # @param value [String]
  # @return [void]
  def full_name=(value)
    self.name = value
  end

  # @return [String] a display-safe name, falling back to email when blank
  def display_name
    name.presence || email
  end

  private

  # Ensures a role-specific profile record exists for the user. This method is
  # triggered after commit so that related models stay consistent with the
  # user's role.
  #
  # @return [void]
  def ensure_role_profile!
    case role
    when self.class.roles[:admin]
      admin_profile || create_admin_profile!
    when self.class.roles[:advisor]
      advisor_profile || create_advisor_profile!
    when self.class.roles[:student]
      student_profile || create_student_profile!
    end
  end

  def should_reconcile_pending_grade_import_rows_for_student?
    role_student? && previous_changes.key?("email")
  end

  def reconcile_pending_grade_import_rows_for_student
    return unless student_profile.present?

    GradeImports::PendingRowReconciler.call(student: student_profile)
  rescue StandardError => e
    Rails.logger.error("Pending grade import reconciliation failed for user #{id}: #{e.class}: #{e.message}")
  end
end
