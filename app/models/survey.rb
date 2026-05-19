# Survey definition composed of categories and questions, with track-based
# assignments and change logging.
class Survey < ApplicationRecord
  belongs_to :program_semester
  belongs_to :creator, class_name: "User", foreign_key: :created_by_id, optional: true

  has_many :categories, inverse_of: :survey, dependent: :destroy
  has_one :legend, class_name: "SurveyLegend", inverse_of: :survey, dependent: :destroy
  has_many :sections,
           class_name: "SurveySection",
           inverse_of: :survey,
           dependent: :destroy
  has_many :questions, through: :categories
  has_many :track_assignments, class_name: "SurveyTrackAssignment", inverse_of: :survey, dependent: :destroy
  has_many :offerings, class_name: "SurveyOffering", inverse_of: :survey, dependent: :destroy
  has_many :survey_response_versions, dependent: :delete_all
  has_many :survey_assignments, inverse_of: :survey, dependent: :destroy
  has_many :advisor_feedback_submissions, dependent: :destroy
  has_many :survey_change_logs, dependent: :nullify
  has_many :feedbacks, foreign_key: :survey_id, class_name: "Feedback", dependent: :destroy
  has_many :student_questions, through: :questions

  accepts_nested_attributes_for :categories, allow_destroy: true
  accepts_nested_attributes_for :legend, update_only: true, allow_destroy: true
  accepts_nested_attributes_for :sections, allow_destroy: true
  accepts_nested_attributes_for :offerings

  before_validation :normalize_title
  before_validation :assign_program_semester_from_semester_name
  after_update_commit :sync_inherited_assignment_deadlines!, if: :saved_change_to_available_until?

  attribute :show_course_competencies_with_survey, :boolean, default: false
  attribute :advisor_numeric_feedback_enabled, :boolean, default: false

  validates :title,
            presence: true,
            uniqueness: {
              scope: :program_semester_id,
              case_sensitive: false,
              message: "already exists for this semester"
            }
  validates :is_active, inclusion: { in: [ true, false ] }
  validate :validate_category_structure
  validate :availability_window_order
  validate :duplicate_title_diagnostic

  # Virtual semester accessor maintained for compatibility with existing
  # views/forms. The canonical value lives in program_semesters.name.
  def semester
    program_semester&.name || @semester_name_input.to_s.strip.presence
  end

  def semester=(value)
    @semester_name_input = value
  end

  # @return [ActiveRecord::Relation<Survey>] newest surveys first
  scope :ordered, -> { order(created_at: :desc) }
  # @return [ActiveRecord::Relation<Survey>] surveys currently active
  scope :active, -> { where(is_active: true) }
  # @return [ActiveRecord::Relation<Survey>] surveys marked inactive
  scope :archived, -> { where(is_active: false) }

  # @return [Array<String>] unique tracks assigned to the survey
  def track_list
    track_assignments.order(:track).pluck(:track).uniq
  end

  def self.canonical_track(value)
    key = ProgramTrack.canonical_key(value)
    return if key.blank?

    ProgramTrack.name_for_key(key)
  end

  # @return [Array<String>] canonical track labels
  def self.track_options
    ProgramTrack.names
  end

  # Replaces the survey's track assignments with the provided list.
  #
  # @param tracks [Enumerable<String>]
  # @return [void]
  def assign_tracks!(tracks)
    normalized = normalize_track_values(tracks)

    transaction do
      track_assignments.where.not(track: normalized).destroy_all
      normalized.each do |track|
        track_assignments.find_or_create_by!(track: track)
      end
    end
  end

  # Records an administrative change to the survey.
  #
  # @param admin [Admin]
  # @param action [String]
  # @param description [String, nil]
  # @return [SurveyChangeLog]
  def log_change!(admin:, action:, description: nil)
    survey_change_logs.create!(
      admin: admin,
      action: action,
      description: description,
      survey_title_snapshot: title
    )
  end

  private

  def duplicate_title_diagnostic
    return if title.blank? || program_semester_id.blank?

    normalized = title.to_s.strip.squeeze(" ")
    return if normalized.blank?

    duplicate = Survey
      .where(program_semester_id: program_semester_id)
      .where("LOWER(title) = ?", normalized.downcase)
      .where.not(id: id)
      .first

    return unless duplicate

    semester_label = program_semester&.name.to_s.strip.presence || "this semester"
    errors.add(
      :base,
      "A survey titled '#{duplicate.title}' already exists for #{semester_label} (Survey ##{duplicate.id}). " \
      "Titles are matched case-insensitively and extra spaces are ignored."
    )
  end

  def validate_category_structure
    active_categories = categories.reject(&:marked_for_destruction?)
    if active_categories.empty?
      errors.add(:base, "Add at least one category to the survey")
      return
    end

    active_categories.each do |category|
      next if category.questions.reject(&:marked_for_destruction?).any?

      errors.add(:base, "Each category must include at least one question")
    end
  end

  def availability_window_order
    return if available_from.blank? || available_until.blank?
    return if available_from <= available_until

    errors.add(:available_until, "must be after Available from")
  end

  def normalize_track_values(values)
    Array(values)
      .flatten
      .map { |value| value.is_a?(String) ? value.strip : value }
      .reject(&:blank?)
      .map do |value|
        canonical = Survey.canonical_track(value)
        next canonical if canonical.present?

        text = value.to_s
        text.length > 255 ? text[0..254] : text
      end
      .reject(&:blank?)
      .uniq
      .sort
  end

  def normalize_title
    self.title = title.to_s.strip.squeeze(" ")
  end

  def assign_program_semester_from_semester_name
    name = @semester_name_input.to_s.strip.squeeze(" ")
    return if name.blank?

    current_name = program_semester&.name.to_s.strip
    return if current_name.present? && current_name.casecmp?(name)

    self.program_semester = ProgramSemester.find_by_name_case_insensitive(name) ||
                            ProgramSemester.create!(name: name)
  end

  def sync_inherited_assignment_deadlines!
    previous_deadline, new_deadline = saved_change_to_available_until

    scope = survey_assignments.where(manual: false)
    scope = if previous_deadline.nil?
      scope.where(available_until: nil)
    else
      scope.where(available_until: [ previous_deadline, nil ])
    end

    scope.update_all(available_until: new_deadline, updated_at: Time.current)
  end
end
