class Department < ApplicationRecord
  has_many :courses, dependent: :restrict_with_error

  before_validation :normalize_code

  validates :code, presence: true, uniqueness: true
  validates :name, presence: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:code) }

  private

  def normalize_code
    self.code = code.to_s.strip.upcase.presence
  end
end
