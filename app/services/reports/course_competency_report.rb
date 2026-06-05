# frozen_string_literal: true

require "csv"

module Reports
  class CourseCompetencyReport
    def initialize(user: nil, params: {})
      @user = user
      @params = params || {}
    end

    def call
      rows = filtered_rows

      {
        filters: filters,
        filter_options: filter_options,
        summary: summary_for(rows),
        course_contributions: course_contributions(rows),
        target_attainment: target_attainment(rows),
        student_course_heatmap: student_course_heatmap(rows)
      }
    end

    def csv
      CSV.generate(headers: true) do |csv|
        csv << [
          "Semester",
          "Course",
          "Competency",
          "Track",
          "Class Of",
          "Students",
          "Rows",
          "Assessed Average",
          "Course Target Average",
          "Met",
          "Below Target",
          "No Target",
          "Met Rate",
          "Release Status"
        ]

        course_contributions(filtered_rows).each do |row|
          csv << [
            row[:semester_names],
            row[:course_code],
            row[:competency_title],
            row[:tracks],
            row[:class_years],
            row[:student_count],
            row[:evidence_count],
            row[:assessed_average],
            row[:course_target_average],
            row[:met_count],
            row[:below_count],
            row[:no_target_count],
            row[:met_rate],
            row[:release_statuses]
          ]
        end
      end
    end

    private

    attr_reader :user, :params

    def filtered_rows
      @filtered_rows ||= begin
        rows = base_scope.to_a
        rows = rows.select { |row| row.grade_import_batch&.program_semester_id.to_s == filters[:program_semester_id] } if filters[:program_semester_id].present?
        rows = rows.select { |row| row.course_code.to_s == filters[:course_code] } if filters[:course_code].present?
        rows = rows.select { |row| row.student&.track.to_s == filters[:track] || row.student&.track_key.to_s == filters[:track] } if filters[:track].present?
        rows = rows.select { |row| row.student&.program_year.to_s == filters[:class_of] } if filters[:class_of].present?
        rows = rows.select { |row| row.student_id.to_s == filters[:student_id] } if filters[:student_id].present?
        rows = rows.select { |row| release_status(row) == filters[:release_status] } if filters[:release_status].present?
        rows
      end
    end

    def base_scope
      scope = GradeCompetencyEvidence
        .joins(:grade_import_batch)
        .merge(GradeImportBatch.reportable)
        .includes(:student, grade_import_batch: { program_semester: :course_grade_release_date })
        .order(:course_code, :competency_title, :student_id)

      if user&.role_advisor?
        advisor_id = user.advisor_profile&.advisor_id
        scope = advisor_id ? scope.joins(:student).where(students: { advisor_id: advisor_id }) : scope.none
      end
      scope
    end

    def filters
      @filters ||= {
        program_semester_id: params[:course_program_semester_id].presence || params[:program_semester_id].presence || semester_id_from_name(params[:semester]),
        course_code: params[:course_code].to_s.strip.presence,
        track: params[:course_track].presence || params[:track].presence,
        class_of: params[:course_class_of].presence || params[:class_of].presence || params[:program_year].presence,
        student_id: normalized_student_id,
        release_status: params[:release_status].presence_in(%w[released embargoed no_semester])
      }.compact
    end

    def semester_id_from_name(value)
      name = value.to_s.strip
      return nil if name.blank? || name.casecmp?("all")

      ProgramSemester.find_by_name_case_insensitive(name)&.id&.to_s
    end

    def normalized_student_id
      value = params[:student_id].to_s.strip
      return nil if value.blank? || value.casecmp?("all")

      value
    end

    def filter_options
      rows = base_scope.to_a

      {
        semesters: ProgramSemester.ordered.map { |semester| [ semester.name, semester.id.to_s ] },
        courses: rows.map(&:course_code).compact_blank.uniq.sort,
        tracks: rows.filter_map { |row| row.student&.track }.compact_blank.uniq.sort,
        class_years: rows.filter_map { |row| row.student&.program_year }.compact.uniq.sort,
        release_statuses: [
          [ "All release statuses", "" ],
          [ "Released", "released" ],
          [ "Embargoed", "embargoed" ],
          [ "No semester", "no_semester" ]
        ]
      }
    end

    def summary_for(rows)
      statuses = rows.map { |row| GradeImports::TargetAttainmentReport.status_for(row.mapped_level, row.course_target_level) }
      denominator = statuses.count(:met) + statuses.count(:below_target)

      {
        course_count: rows.map(&:course_code).compact_blank.uniq.size,
        competency_count: rows.map(&:competency_title).compact_blank.uniq.size,
        student_count: rows.map(&:student_id).compact.uniq.size,
        evidence_count: rows.size,
        met_count: statuses.count(:met),
        below_count: statuses.count(:below_target),
        no_target_count: statuses.count(:no_target),
        met_rate: denominator.positive? ? ((statuses.count(:met).to_f / denominator) * 100).round(1) : nil
      }
    end

    def course_contributions(rows)
      rows.group_by { |row| [ row.course_code.presence || "No course code", row.competency_title.presence || "No competency" ] }
        .map do |(course_code, competency_title), group|
          build_group_summary(group).merge(
            course_code: course_code,
            competency_title: competency_title,
            semester_names: group.map { |row| row.grade_import_batch&.program_semester&.name }.compact_blank.uniq.sort.join("; "),
            tracks: group.filter_map { |row| row.student&.track }.compact_blank.uniq.sort.join("; "),
            class_years: group.filter_map { |row| row.student&.program_year }.compact.uniq.sort.join("; "),
            release_statuses: group.map { |row| release_status_label(row) }.uniq.sort.join("; ")
          )
        end
        .sort_by { |row| [ row[:course_code].to_s, row[:competency_title].to_s ] }
    end

    def target_attainment(rows)
      GradeImports::TargetAttainmentReport.new(GradeCompetencyEvidence.where(id: rows.map(&:id))).by_semester_course_and_competency
    end

    def student_course_heatmap(rows)
      rows.group_by { |row| [ row.student_id, row.course_code.presence || "No course code", row.grade_import_batch&.program_semester&.name.presence || "No semester" ] }
        .map do |(student_id, course_code, semester_name), group|
          student = group.first.student
          statuses = group.map { |row| GradeImports::TargetAttainmentReport.status_for(row.mapped_level, row.course_target_level) }
          assessed_values = group.filter_map(&:mapped_level).map(&:to_f)

          {
            student_id: student_id,
            student_name: student&.user&.name || "Student #{student_id}",
            track: student&.track,
            class_of: student&.program_year,
            semester_names: semester_name,
            course_code: course_code,
            average: average(assessed_values),
            evidence_count: group.size,
            below_count: statuses.count(:below_target),
            no_target_count: statuses.count(:no_target),
            status: heatmap_status(average(assessed_values), statuses)
          }
        end
        .sort_by { |row| [ row[:student_name].to_s.downcase, row[:semester_names].to_s, row[:course_code].to_s ] }
        .first(150)
    end

    def build_group_summary(rows)
      statuses = rows.map { |row| GradeImports::TargetAttainmentReport.status_for(row.mapped_level, row.course_target_level) }
      denominator = statuses.count(:met) + statuses.count(:below_target)

      {
        student_count: rows.map(&:student_id).compact.uniq.size,
        evidence_count: rows.size,
        assessed_average: average(rows.filter_map(&:mapped_level).map(&:to_f)),
        course_target_average: average(rows.filter_map(&:course_target_level).map(&:to_f)),
        met_count: statuses.count(:met),
        below_count: statuses.count(:below_target),
        no_target_count: statuses.count(:no_target),
        met_rate: denominator.positive? ? ((statuses.count(:met).to_f / denominator) * 100).round(1) : nil
      }
    end

    def release_status(row)
      semester = row.grade_import_batch&.program_semester
      return "no_semester" if semester.blank?

      release = semester.course_grade_release_date
      release.blank? || release.released? ? "released" : "embargoed"
    end

    def release_status_label(row)
      case release_status(row)
      when "released" then "Released"
      when "embargoed" then "Embargoed"
      else "No semester"
      end
    end

    def heatmap_status(average, statuses)
      return "attention" if statuses.include?(:below_target)
      return "missing" if average.blank?
      return "strong" if average.to_f >= 4.0
      return "watch" if average.to_f >= 3.0

      "attention"
    end

    def average(values)
      values = values.compact
      return nil if values.empty?

      (values.sum / values.size).round(2)
    end
  end
end
