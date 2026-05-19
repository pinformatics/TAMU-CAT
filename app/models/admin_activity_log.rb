# Tracks administrative actions beyond survey-specific changes so the
# dashboard can show a consolidated activity feed.
class AdminActivityLog < ApplicationRecord
  ACTIONS = %w[
    role_update
    advisor_assignment
    bulk_advisor_assignment
    track_update
    course_release_date_update
    student_data_export
    member_removal
    other
  ].freeze

  belongs_to :admin, class_name: "User"
  belongs_to :subject, polymorphic: true, optional: true

  validates :action, presence: true
  validates :description, presence: true

  scope :recent, -> { order(created_at: :desc) }

  # Records a new admin action entry.
  #
  # @param admin [User]
  # @param action [String]
  # @param description [String]
  # @param subject [ApplicationRecord, nil]
  # @param metadata [Hash]
  # @return [AdminActivityLog]
  def self.record!(admin:, action:, description:, subject: nil, metadata: {})
    create!(
      admin: admin,
      action: ACTIONS.include?(action) ? action : "other",
      description: description,
      subject_type: subject&.class&.name,
      subject_id: subject&.id,
      metadata: metadata.presence || {}
    )
  end
end
