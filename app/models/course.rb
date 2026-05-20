class Course < ApplicationRecord
  belongs_to :department
  has_many :course_offerings, dependent: :restrict_with_error

  before_validation :normalize_number

  validates :number, presence: true, uniqueness: { scope: :department_id }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { joins(:department).order("departments.code ASC", :number) }

  def catalog_code
    [ department&.code, number ].compact_blank.join("-")
  end

  def display_name
    title.present? ? "#{catalog_code} #{title}" : catalog_code
  end

  private

  def normalize_number
    self.number = number.to_s.strip.presence
  end
end
