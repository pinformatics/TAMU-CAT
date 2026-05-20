class Competency < ApplicationRecord
  belongs_to :domain
  has_many :competency_target_levels, dependent: :nullify
  has_many :grade_competency_evidences, dependent: :nullify
  has_many :grade_competency_ratings, dependent: :nullify
  has_many :grade_import_pending_rows, dependent: :nullify

  validates :title, presence: true, uniqueness: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :ordered, -> { joins(:domain).order("domains.position ASC", :position, :title) }

  def self.find_by_normalized_title(value)
    normalized = normalize_title(value)
    return if normalized.blank?

    all.find { |competency| normalize_title(competency.title) == normalized }
  end

  def self.normalize_title(value)
    value.to_s
         .downcase
         .gsub("&", " and ")
         .gsub(/[^\p{Alnum}]+/, " ")
         .squeeze(" ")
         .strip
  end
end
