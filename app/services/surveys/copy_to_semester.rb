# frozen_string_literal: true

module Surveys
  # Copies a survey definition into another semester without assigning students.
  class CopyToSemester
    class Error < StandardError; end

    SURVEY_ATTRIBUTES = %w[
      title
      track
      description
      is_active
      available_from
      available_until
      show_course_competencies_with_survey
      advisor_numeric_feedback_enabled
    ].freeze

    SKIPPED_COPY_COLUMNS = %w[
      id
      survey_id
      category_id
      survey_section_id
      parent_question_id
      created_at
      updated_at
    ].freeze

    def self.call(source_survey:, target_semester:, actor:)
      new(source_survey:, target_semester:, actor:).call
    end

    def initialize(source_survey:, target_semester:, actor:)
      @source_survey = source_survey
      @target_semester = target_semester
      @actor = actor
    end

    def call
      raise Error, "Choose a semester to copy into." unless target_semester
      if source_survey.program_semester_id == target_semester.id
        raise Error, "Choose a different semester. This survey already belongs to #{target_semester.name}."
      end

      Survey.transaction do
        copied_survey = build_survey_copy
        ensure_title_available!(copied_survey)
        copied_survey.save!(validate: false)

        section_map = copy_sections(copied_survey)
        parent_question_links = copy_categories_and_questions(copied_survey, section_map)
        copy_legend(copied_survey)
        link_parent_questions(parent_question_links)
        copied_survey.assign_tracks!(source_survey.track_list)
        copy_offerings(copied_survey)

        copied_survey.reload
        raise ActiveRecord::RecordInvalid, copied_survey unless copied_survey.valid?

        copied_survey.log_change!(
          admin: actor,
          action: "copy",
          description: "Copied from #{source_survey.title} (#{source_survey.semester}) without assigning students"
        )

        copied_survey
      end
    end

    private

    attr_reader :source_survey, :target_semester, :actor

    def build_survey_copy
      attrs = source_survey.attributes.slice(*(SURVEY_ATTRIBUTES & Survey.column_names))
      Survey.new(attrs).tap do |survey|
        survey.program_semester = target_semester
        survey.creator = actor
      end
    end

    def ensure_title_available!(copied_survey)
      duplicate = Survey
        .where(program_semester: target_semester)
        .where("LOWER(title) = ?", copied_survey.title.to_s.downcase)
        .exists?

      return unless duplicate

      raise Error, "A survey titled '#{copied_survey.title}' already exists for #{target_semester.name}."
    end

    def copy_sections(copied_survey)
      source_survey.sections.ordered.each_with_object({}) do |section, section_map|
        section_map[section.id] = copied_survey.sections.create!(copyable_attributes(section))
      end
    end

    def copy_categories_and_questions(copied_survey, section_map)
      @question_map = {}
      parent_question_links = []

      source_survey.categories.includes(:questions).each do |category|
        copied_category = copied_survey.categories.create!(copyable_attributes(category)) do |record|
          record.section = section_map[category.survey_section_id] if category.survey_section_id.present?
        end

        category.questions.ordered.each do |question|
          copied_question = copied_category.questions.create!(copyable_attributes(question))
          @question_map[question.id] = copied_question
          if question.respond_to?(:parent_question_id) && question.parent_question_id.present?
            parent_question_links << [ copied_question, question.parent_question_id ]
          end
        end
      end

      parent_question_links
    end

    def copy_legend(copied_survey)
      return unless source_survey.legend

      copied_survey.create_legend!(copyable_attributes(source_survey.legend))
    end

    def link_parent_questions(parent_question_links)
      parent_question_links.each do |copied_question, source_parent_id|
        copied_parent = @question_map[source_parent_id]
        next unless copied_parent

        copied_question.update!(parent_question_id: copied_parent.id)
      end
    end

    def copy_offerings(copied_survey)
      return unless SurveyOffering.data_source_ready?

      source_survey.offerings.find_each do |offering|
        copied_survey.offerings.create!(copyable_attributes(offering))
      end
    end

    def copyable_attributes(record)
      record.attributes.except(*SKIPPED_COPY_COLUMNS)
    end
  end
end
