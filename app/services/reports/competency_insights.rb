# frozen_string_literal: true

module Reports
  class CompetencyInsights
    def initialize(user:, params: {})
      @user = user
      @params = normalize_params(params)
    end

    def call
      {
        filters: matrix_payload[:filters],
        filter_options: filter_options,
        cohort_comparison: cohort_comparison,
        heatmap: heatmap_rows,
        target_attainment: target_attainment_rows
      }
    end

    private

    attr_reader :user, :params

    def normalize_params(raw_params)
      normalized = raw_params.to_h.with_indifferent_access

      if normalized[:domain].blank? && normalized[:category_id].present?
        domain = domain_name_for_filter(normalized[:category_id])
        normalized[:domain] = domain if domain.present?
      end

      if normalized[:competencies].blank? && normalized[:competency].present?
        competency = competency_title_for_filter(normalized[:competency])
        normalized[:competencies] = [ competency ] if competency.present?
      end

      normalized
    end

    def domain_name_for_filter(value)
      text = value.to_s.strip
      return nil if text.blank?

      if text.match?(/\A\d+\z/)
        category_name = Category.find_by(id: text)&.name
        return category_name if Reports::DataAggregator::REPORT_DOMAINS.include?(category_name)
      end

      Reports::DataAggregator::REPORT_DOMAINS.find do |name|
        name == text || name.parameterize(separator: "_") == text
      end
    end

    def competency_title_for_filter(value)
      text = value.to_s.strip
      return nil if text.blank?

      Reports::DataAggregator::COMPETENCY_TITLES.find do |title|
        title == text || title.parameterize(separator: "_") == text
      end
    end

    def matrix_payload
      @matrix_payload ||= Admin::CompetencyMatrix.new(params: params, actor_user: user).call
    end

    def students
      matrix_payload[:students]
    end

    def domains
      matrix_payload[:domains]
    end

    def filter_options
      (matrix_payload[:filter_options] || {}).merge(students: student_options)
    end

    def student_options
      students.map do |student|
        {
          id: student[:id],
          name: student[:name],
          track: student[:track],
          program_year: student[:program_year]
        }
      end
    end

    def cohort_comparison
      selected_semester_names.flat_map do |semester_name|
        payload = matrix_payload_for_semester(semester_name)
        cohort_comparison_for(payload[:students], semester_name)
      end
    end

    def cohort_comparison_for(source_students, semester_name)
      Array(source_students).group_by { |student| student[:program_year].presence || "Unassigned" }.map do |program_year, cohort_students|
        {
          semester: semester_name,
          program_year: program_year,
          student_count: cohort_students.size,
          self_average: average_for(cohort_students, :self_rating),
          advisor_average: average_for(cohort_students, :advisor_rating),
          course_average: average_for(cohort_students, :course_rating),
          below_target_count: below_target_count_for(cohort_students)
        }
      end.sort_by { |row| [ row[:semester].to_s, row[:program_year].to_s ] }
    end

    def selected_semester_names
      selected = params[:semester].to_s.strip
      return [ selected ] if selected.present? && !selected.casecmp?("all")

      names = ProgramSemester.ordered.pluck(:name).compact_blank.uniq
      names.presence || [ "All semesters" ]
    end

    def matrix_payload_for_semester(semester_name)
      return matrix_payload if params[:semester].to_s == semester_name.to_s
      return matrix_payload if semester_name == "All semesters"

      Admin::CompetencyMatrix.new(params: params.merge(semester: semester_name), actor_user: user).call
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
