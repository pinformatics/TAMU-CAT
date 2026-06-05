class CourseCompetencyTarget < ApplicationRecord
  belongs_to :course_offering
  belongs_to :competency

  validates :target_level,
            presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 5 }
  validates :competency_id, uniqueness: { scope: :course_offering_id }

  scope :ordered, -> {
    joins(course_offering: { course: :department })
      .joins(competency: :domain)
      .includes(course_offering: { course: :department }, competency: :domain)
      .order(
        "departments.code ASC",
        "courses.number ASC",
        "course_offerings.section_number ASC",
        "domains.position ASC",
        "competencies.position ASC",
        "competencies.title ASC"
      )
  }

  def course_code
    course_offering&.display_code
  end

  def course_title
    course_offering&.course&.title
  end

  def course_name
    course_offering&.course&.display_name
  end

  def competency_title
    competency&.title
  end

  def semester_name
    course_offering&.program_semester&.name
  end
end
