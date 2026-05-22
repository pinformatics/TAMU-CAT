# frozen_string_literal: true

module GradeImports
  class TargetAttainmentReport
    def self.status_for(assessed_level, course_target_level)
      return :no_target if course_target_level.blank?
      return :no_assessed_level if assessed_level.blank?

      assessed_level.to_i >= course_target_level.to_i ? :met : :below_target
    end

    def self.export_label(assessed_level, course_target_level)
      case status_for(assessed_level, course_target_level)
      when :met then "Yes"
      when :below_target then "No - below target"
      when :no_assessed_level then "No assessed level"
      else "No target"
      end
    end

    def self.ui_label(assessed_level, course_target_level)
      case status_for(assessed_level, course_target_level)
      when :met then "Met"
      when :below_target then "Below target"
      when :no_assessed_level then "No assessed level"
      else "No target"
      end
    end

    def initialize(scope = GradeCompetencyEvidence.all)
      @scope = scope
    end

    def by_course
      grouped_rows([ :course_code ]).map do |keys, rows|
        build_summary(rows).merge(course_code: keys.fetch(:course_code).presence || "No course code")
      end.sort_by { |row| row[:course_code].to_s }
    end

    def by_course_and_competency
      grouped_rows([ :course_code, :competency_title ]).map do |keys, rows|
        build_summary(rows).merge(
          course_code: keys.fetch(:course_code).presence || "No course code",
          competency_title: keys.fetch(:competency_title).presence || "No competency"
        )
      end.sort_by { |row| [ row[:course_code].to_s, row[:competency_title].to_s ] }
    end

    def by_semester_course_and_competency
      rows = @scope.includes(grade_import_batch: :program_semester).to_a

      rows
        .group_by do |row|
          [
            row.grade_import_batch&.program_semester&.name.presence || "No semester",
            row.course_code.presence || "No course code",
            row.competency_title.presence || "No competency"
          ]
        end
        .map do |(semester_name, course_code, competency_title), group|
          build_summary(group).merge(
            semester_name: semester_name,
            course_code: course_code,
            competency_title: competency_title
          )
        end
        .sort_by { |row| [ row[:semester_name].to_s, row[:course_code].to_s, row[:competency_title].to_s ] }
    end

    private

    def grouped_rows(keys)
      @scope.to_a.group_by do |row|
        keys.index_with { |key| row.public_send(key) }
      end
    end

    def build_summary(rows)
      met_count = rows.count { |row| self.class.status_for(row.mapped_level, row.course_target_level) == :met }
      below_count = rows.count { |row| self.class.status_for(row.mapped_level, row.course_target_level) == :below_target }
      no_target_count = rows.count { |row| self.class.status_for(row.mapped_level, row.course_target_level) == :no_target }
      no_assessed_count = rows.count { |row| self.class.status_for(row.mapped_level, row.course_target_level) == :no_assessed_level }
      denominator = met_count + below_count
      assessed_levels = rows.filter_map(&:mapped_level).map(&:to_f)
      target_levels = rows.filter_map(&:course_target_level).map(&:to_f)

      {
        total_count: rows.size,
        met_count: met_count,
        below_count: below_count,
        no_target_count: no_target_count,
        no_assessed_count: no_assessed_count,
        met_rate: denominator.positive? ? ((met_count.to_f / denominator) * 100).round(1) : nil,
        assessed_average: average(assessed_levels),
        course_target_average: average(target_levels),
        assessed_min: assessed_levels.min,
        assessed_max: assessed_levels.max,
        course_target_min: target_levels.min,
        course_target_max: target_levels.max
      }
    end

    def average(values)
      return nil if values.blank?

      (values.sum / values.size).round(2)
    end
  end
end
