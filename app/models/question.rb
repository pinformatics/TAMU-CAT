require "json"

# Survey prompt tied to a category, supporting multiple response types.
class Question < ApplicationRecord
  PROMPT_FORMATS = %w[plain_text rich_text].freeze
  RICH_TEXT_TAG_PATTERN = %r{</?(strong|b|em|i|u|br)\b[^>]*>}i.freeze

  enum :question_type, {
    multiple_choice: "multiple_choice",
    dropdown: "dropdown",
    short_answer: "short_answer",
    evidence: "evidence",
    integer: "integer"
  }, prefix: true

  store_accessor :configuration, :prompt_format, :integer_min, :integer_max

  belongs_to :category

  def self.sub_question_columns_supported?
    conn = connection
    return false unless conn.data_source_exists?(table_name)

    conn.column_exists?(table_name, :parent_question_id) &&
      conn.column_exists?(table_name, :sub_question_order)
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError
    false
  end

  if sub_question_columns_supported?
    belongs_to :parent_question,
               class_name: "Question",
               optional: true,
               inverse_of: :sub_questions
    has_many :sub_questions,
             class_name: "Question",
             foreign_key: :parent_question_id,
             inverse_of: :parent_question,
             dependent: :destroy
  else
    def parent_question
      nil
    end

    def sub_questions
      Question.none
    end
  end
  has_many :student_questions, dependent: :destroy
  has_many :students, through: :student_questions

  alias_attribute :question, :question_text
  alias_attribute :required, :is_required

  validates :category, presence: true
  validates :question_text, presence: true
  validates :question_order, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :question_type, presence: true, inclusion: { in: question_types.values }
  validates :prompt_format, inclusion: { in: PROMPT_FORMATS }, allow_blank: true
  validates :sub_question_order,
            numericality: { greater_than_or_equal_to: 0, only_integer: true },
            allow_nil: true,
            if: ->(record) { record.has_attribute?(:sub_question_order) }
  validates :program_target_level,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 1,
              less_than_or_equal_to: 5
            },
            allow_nil: true
  validates :integer_min,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_blank: true
  validates :integer_max,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_blank: true
  validate :validate_integer_bounds

  # @return [ActiveRecord::Relation<Question>] questions ordered for display
  scope :ordered, lambda {
    relation = order(:question_order)
    if column_names.include?("parent_question_id") && column_names.include?("sub_question_order")
      table = connection.quote_table_name(table_name)
      relation
        .order(Arel.sql("COALESCE(#{table}.parent_question_id, #{table}.id)"))
        .order(Arel.sql("CASE WHEN #{table}.parent_question_id IS NULL THEN 0 ELSE 1 END"))
        .order(:sub_question_order, :id)
    else
      relation.order(:id)
    end
  }
  scope :parent_questions, lambda {
    column_names.include?("parent_question_id") ? where(parent_question_id: nil) : all
  }
  scope :sub_questions_only, lambda {
    column_names.include?("parent_question_id") ? where.not(parent_question_id: nil) : none
  }

  before_validation :ensure_question_order
  before_validation :ensure_sub_question_order

  # @return [Boolean] whether the question is required
  def required?
    is_required?
  end

  # Parses the serialized answer options into an array, gracefully handling
  # legacy formats.
  #
  # @return [Array<String>]
  def answer_options_list
    raw = answer_options.to_s
    return [] if raw.blank?

    parsed = JSON.parse(raw) rescue nil
    if parsed.is_a?(Array)
      list = parsed.map do |entry|
        case entry
        when String
          entry.to_s.squish
        when Array
          entry[0].to_s.squish
        when Hash
          (entry["label"] || entry[:label] || entry["value"] || entry[:value]).to_s.squish
        else
          entry.to_s.squish
        end
      end
      list
    else
      # Legacy fallback: accept comma-separated and newline-separated lists.
      list = raw
        .gsub(/[\[\]\"“”]/, "")
        .split(/[\r\n,]+/)
        .map { |token| token.to_s.squish }
        .reject(&:empty?)

      list
    end
  end

  # Returns a normalized list of [label, value] pairs for choice-style questions.
  #
  # Supports answer_options stored as:
  # - ["Yes", "No"]
  # - [["Mastery (5)", "5"], ...]
  # - [{"label":"Mastery (5)","value":"5"}, ...]
  #
  # @return [Array<Array(String, String)>]
  def answer_option_pairs
    raw = answer_options.to_s
    return [] if raw.blank?

    parsed = JSON.parse(raw) rescue nil
    list = parsed.is_a?(Array) ? parsed : answer_options_list

    pairs = Array(list).filter_map do |entry|
      case entry
      when Array
        next unless entry.size >= 2

        label = entry[0].to_s.squish
        value = entry[1].to_s.squish
        next if label.blank? || value.blank?

        [ label, value ]
      when Hash
        label = (entry["label"] || entry[:label]).to_s.squish
        value = (entry["value"] || entry[:value] || label).to_s.squish
        next if label.blank? || value.blank?

        [ label, value ]
      else
        str = entry.to_s.squish
        next if str.blank?

        [ str, str ]
      end
    end

    pairs
  end

  # Returns a normalized list of answer option definitions including metadata.
  #
  # Supports answer_options stored as:
  # - ["Yes", "No"]
  # - [["Mastery (5)", "5"], ...]
  # - [{"label":"Other — Please describe...","value":"0","requires_text":true}, ...]
  #
  # @return [Array<Hash>] list of {label:, value:, requires_text:}
  def answer_option_definitions
    raw = answer_options.to_s
    return [] if raw.blank?

    parsed = JSON.parse(raw) rescue nil
    list = parsed.is_a?(Array) ? parsed : answer_options_list

    Array(list).filter_map do |entry|
      case entry
      when Array
        next unless entry.size >= 2
        label = entry[0].to_s.squish
        value = entry[1].to_s.squish
        next if label.blank? || value.blank?
        { label: label, value: value, requires_text: label.downcase.start_with?("other") }
      when Hash
        label = (entry["label"] || entry[:label]).to_s.squish
        value = (entry["value"] || entry[:value] || label).to_s.squish
        next if label.blank? || value.blank?

        requires_text = entry.key?("requires_text") || entry.key?(:requires_text) ? !!(entry["requires_text"] || entry[:requires_text]) : nil
        requires_text = entry.key?("other_text") || entry.key?(:other_text) ? !!(entry["other_text"] || entry[:other_text]) : requires_text
        requires_text = entry.key?("other") || entry.key?(:other) ? !!(entry["other"] || entry[:other]) : requires_text
        requires_text = label.downcase.start_with?("other") if requires_text.nil?

        { label: label, value: value, requires_text: requires_text }
      else
        str = entry.to_s.squish
        next if str.blank?
        { label: str, value: str, requires_text: str.downcase.start_with?("other") }
      end
    end
  end

  # Whether a given submitted value corresponds to an option that requires
  # accompanying free-text ("Other"-style).
  #
  # @param value [String]
  # @return [Boolean]
  def answer_option_requires_text?(value)
    candidate = value.to_s
    return false if candidate.blank?

    defs = answer_option_definitions
    entry = defs.find { |opt| opt[:value].to_s == candidate }
    return entry[:requires_text] if entry

    candidate.strip.downcase.start_with?("other")
  end

  # @return [Array<String>] values for choice-style questions.
  def answer_option_values
    answer_option_pairs.map { |(_label, value)| value }
  end

  # @return [Boolean] whether this question uses discrete choice options
  def choice_question?
    question_type_multiple_choice? || question_type_dropdown?
  end

  # @return [Boolean] whether this question is a sub-question
  def sub_question?
    return false unless has_attribute?(:parent_question_id)

    parent_question_id.present?
  end

  # @return [Boolean] whether this question prompt should render rich text.
  def rich_text_prompt?
    return true if effective_prompt_format == "rich_text"

    prompt_format.blank? && question_text_contains_allowed_rich_text_tags?
  end

  # @return [String] configured prompt format with default fallback.
  def effective_prompt_format
    prompt_format.presence || "plain_text"
  end

  # @return [Integer] minimum accepted integer for integer questions.
  def integer_min_value
    integer_min.present? ? integer_min.to_i : 1
  end

  # @return [Integer, nil] maximum accepted integer for integer questions.
  def integer_max_value
    integer_max.present? ? integer_max.to_i : nil
  end

  private

  def validate_integer_bounds
    return unless integer_min.present? && integer_max.present?
    return unless integer_min.to_i > integer_max.to_i

    errors.add(:integer_max, "must be greater than or equal to minimum")
  end

  def question_text_contains_allowed_rich_text_tags?
    question_text.to_s.match?(RICH_TEXT_TAG_PATTERN)
  end

  def ensure_question_order
    if has_attribute?(:parent_question_id) && parent_question.present?
      self.question_order = parent_question.question_order
      return
    end

    return if question_order.present?

    self.question_order = (category&.questions&.maximum(:question_order) || 0) + 1
  end

  def ensure_sub_question_order
    return unless has_attribute?(:parent_question_id)
    return unless has_attribute?(:sub_question_order)
    return unless parent_question.present?
    return if sub_question_order.present?

    # Prefer in-memory siblings when building nested records during seeding.
    in_memory_siblings = parent_question.sub_questions.to_a
    in_memory_max = in_memory_siblings.filter_map { |question| question.has_attribute?(:sub_question_order) ? question.sub_question_order : nil }.max
    db_max = parent_question.persisted? ? parent_question.sub_questions.maximum(:sub_question_order) : nil

    self.sub_question_order = [ in_memory_max, db_max, 0 ].compact.max + 1
  end
end
