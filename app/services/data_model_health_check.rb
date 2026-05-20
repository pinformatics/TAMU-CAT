class DataModelHealthCheck
  Check = Struct.new(:key, :label, :count, :severity, keyword_init: true) do
    def ok?
      count.to_i.zero?
    end
  end

  Section = Struct.new(:key, :label, :checks, keyword_init: true) do
    def issue_count
      checks.sum { |check| check.count.to_i }
    end

    def ok?
      issue_count.zero?
    end
  end

  def call
    sections = [
      student_section,
      advisor_assignment_section,
      competency_reference_section,
      course_reference_section
    ]

    {
      generated_at: Time.current,
      sections: sections,
      issue_count: sections.sum(&:issue_count),
      critical_count: sections.sum { |section| section.checks.select { |check| check.severity == :critical }.sum { |check| check.count.to_i } },
      warning_count: sections.sum { |section| section.checks.select { |check| check.severity == :warning }.sum { |check| check.count.to_i } }
    }
  end

  private

  def student_section
    Section.new(
      key: :students,
      label: "Student records",
      checks: [
        check(:students_without_user, "Student profiles without user accounts", students_without_user_count, :critical),
        check(:current_without_advisor, "Current students without advisors", Student.current_records.where(advisor_id: nil).count, :warning),
        check(:current_without_track, "Current students without tracks", Student.current_records.where(track: [ nil, "" ]).count, :warning),
        check(:current_without_program_year, "Current students without class year", Student.current_records.where(program_year: nil).count, :warning),
        check(:current_without_uin, "Current students without UIN", Student.current_records.where(uin: [ nil, "" ]).count, :warning),
        check(:duplicate_uins, "Duplicate UIN values", duplicate_uin_count, :critical)
      ]
    )
  end

  def advisor_assignment_section
    Section.new(
      key: :advisor_assignments,
      label: "Advisor assignment history",
      checks: [
        check(:duplicate_current_assignments, "Students with multiple current advisor assignments", duplicate_current_assignment_count, :critical),
        check(:advisor_history_mismatch, "Students whose current advisor differs from assignment history", advisor_history_mismatch_count, :warning)
      ]
    )
  end

  def competency_reference_section
    Section.new(
      key: :competency_references,
      label: "Competency references",
      checks: [
        check(:target_levels_missing_competency, "Target levels missing competency links", missing_competency_count(CompetencyTargetLevel), :critical),
        check(:evidence_missing_competency, "Course evidence missing competency links", missing_competency_count(GradeCompetencyEvidence), :critical),
        check(:ratings_missing_competency, "Derived ratings missing competency links", missing_competency_count(GradeCompetencyRating), :critical),
        check(:pending_rows_missing_competency, "Pending import rows missing competency links", missing_competency_count(GradeImportPendingRow), :critical)
      ]
    )
  end

  def course_reference_section
    Section.new(
      key: :course_references,
      label: "Course references",
      checks: [
        check(:parseable_evidence_missing_offering, "Parseable course evidence without course offerings", parseable_missing_offering_count(GradeCompetencyEvidence), :warning),
        check(:parseable_pending_rows_missing_offering, "Parseable pending rows without course offerings", parseable_missing_offering_count(GradeImportPendingRow), :warning)
      ]
    )
  end

  def check(key, label, count, severity)
    Check.new(key: key, label: label, count: count.to_i, severity: severity)
  end

  def students_without_user_count
    Student.left_outer_joins(:user).where(users: { id: nil }).count
  end

  def duplicate_uin_count
    Student.where.not(uin: [ nil, "" ]).group(:uin).having("COUNT(*) > 1").count.size
  end

  def duplicate_current_assignment_count
    StudentAdvisorAssignment.current.group(:student_id).having("COUNT(*) > 1").count.size
  end

  def advisor_history_mismatch_count
    Student.current_records
      .joins("LEFT JOIN student_advisor_assignments current_assignments ON current_assignments.student_id = students.student_id AND current_assignments.ends_on IS NULL AND current_assignments.primary_assignment = TRUE")
      .where.not(advisor_id: nil)
      .where("current_assignments.id IS NULL OR current_assignments.advisor_id IS DISTINCT FROM students.advisor_id")
      .count
  end

  def missing_competency_count(model)
    return 0 unless model.column_names.include?("competency_id")

    model.where.not(competency_title: [ nil, "" ]).where(competency_id: nil).count
  end

  def parseable_missing_offering_count(model)
    return 0 unless model.column_names.include?("course_offering_id")
    return 0 unless model.column_names.include?("course_code")

    model
      .where.not(course_code: [ nil, "" ])
      .where(course_offering_id: nil)
      .pluck(:course_code)
      .count { |course_code| CourseOffering.parse_source_code(course_code).present? }
  end
end
