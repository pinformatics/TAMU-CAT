# frozen_string_literal: true

module Reports
  class CompetencyInsights
    def initialize(user:, params: {})
      @user = user
      @params = params
    end

    def call
      {
        filters: matrix_payload[:filters],
        cohort_comparison: cohort_comparison,
        heatmap: heatmap_rows,
        target_attainment: target_attainment_rows
      }
    end

    private

    attr_reader :user, :params

    def matrix_payload
      @matrix_payload ||= Admin::CompetencyMatrix.new(params: params, actor_user: user).call
    end

    def students
      matrix_payload[:students]
    end

    def domains
      matrix_payload[:domains]
    end

    def cohort_comparison
      students.group_by { |student| student[:program_year].presence || "Unassigned" }.map do |program_year, cohort_students|
        {
          program_year: program_year,
          student_count: cohort_students.size,
          self_average: average_for(cohort_students, :self_rating),
          advisor_average: average_for(cohort_students, :advisor_rating),
          course_average: average_for(cohort_students, :course_rating),
          below_target_count: below_target_count_for(cohort_students)
        }
      end.sort_by { |row| row[:program_year].to_s }
    end

    def heatmap_rows
      students.map do |student|
        {
          student_id: student[:id],
          student_name: student[:name],
          track: student[:track],
          program_year: student[:program_year],
          domains: domains.map do |domain|
            values = domain[:competencies].filter_map do |competency|
              ratings = student.dig(:ratings, competency[:title]) || {}
              ratings[:course_rating] || ratings[:self_rating]
            end

            {
              name: domain[:name],
              average: average(values),
              status: heatmap_status(average(values))
            }
          end
        }
      end
    end

    def target_attainment_rows
      students.map do |student|
        ratings = student[:ratings] || {}

        {
          student_id: student[:id],
          met_count: ratings.count { |_title, row| target_met?(row) },
          total_count: ratings.size
        }
      end
    end

    def average_for(cohort_students, rating_key)
      values = cohort_students.flat_map do |student|
        student[:ratings].values.filter_map { |ratings| ratings[rating_key] }
      end

      average(values)
    end

    def below_target_count_for(cohort_students)
      cohort_students.sum do |student|
        student[:ratings].values.count do |ratings|
          target = ratings[:program_target]
          next false if target.blank?

          [ ratings[:course_rating], ratings[:self_rating] ].compact.any? { |value| value.to_f < target.to_f }
        end
      end
    end

    def target_met?(ratings)
      target = ratings[:program_target]
      value = ratings[:course_rating].presence || ratings[:self_rating].presence

      target.present? && value.present? && value.to_f >= target.to_f
    end

    def average(values)
      values = values.compact
      return nil if values.empty?

      (values.sum(&:to_f) / values.size).round(2)
    end

    def heatmap_status(value)
      return "missing" if value.blank?
      return "strong" if value.to_f >= 4.0
      return "watch" if value.to_f >= 3.0

      "attention"
    end
  end
end
