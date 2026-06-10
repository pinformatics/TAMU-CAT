# frozen_string_literal: true

require "digest"
require "active_support/number_helper"

# Builds the composite assessment PDF that merges student responses and advisor feedback.
class CompositeReportGenerator
  class MissingDependency < StandardError; end
  class GenerationError < StandardError; end

  CACHE_TTL = 6.hours
  MAX_EVIDENCE_HISTORY = Integer(ENV.fetch("COMPOSITE_REPORT_MAX_EVIDENCE_HISTORY", 5))
  PDF_RENDER_VERSION = 4
  # Lightweight value object so callers can ensure temporary files are cleaned up.
  class Result
    attr_reader :path, :size_bytes

    def initialize(path:, cached:, size_bytes:, cleanup: nil)
      @path = path
      @cached = cached
      @size_bytes = size_bytes
      @cleanup = cleanup
    end

    def cached?
      @cached
    end

    def cleanup!
      @cleanup&.call
      @cleanup = nil
    end
  end

  include ActiveSupport::NumberHelper

  def initialize(survey_response:, cache: true, logger: Rails.logger, viewer_mode: :staff)
    @survey_response = survey_response
    @cache_enabled = cache
    @logger = logger || Rails.logger
    @viewer_mode = viewer_mode.to_sym
  end

  # Renders (or retrieves) the PDF payload for the survey response composite report.
  #
  # @return [Result]
  def render
    ensure_dependency!
    result = cache_enabled? ? render_with_cache : render_without_cache

    unless result&.path && File.exist?(result.path)
      raise GenerationError, "Composite PDF generation failed"
    end

    result
  rescue MissingDependency
    raise
  rescue => e
    log_prefix = "[CompositeReportGenerator] generation failed for SurveyResponse=#{@survey_response.id}"
    message = [
      "#{log_prefix}: #{e.class} - #{e.message}",
      e.backtrace&.first(10)&.join("\n")
    ].compact.join("\n")
    logger.error(message)
    raise GenerationError, e.message
  end

  # Exposed for tests to verify cache invalidation logic applies expected inputs.
  #
  # @return [String]
  def cache_fingerprint
    responses = question_responses
    feedback_entries = feedback_records

    response_updated = responses.filter_map { |r| r.updated_at&.to_i }
    response_created = responses.filter_map { |r| r.created_at&.to_i }

    feedback_updated = feedback_entries.filter_map { |f| f.updated_at&.to_i }
    feedback_created = feedback_entries.filter_map { |f| f.created_at&.to_i }

    components = [
      PDF_RENDER_VERSION,
      @survey_response.student_id,
      student.updated_at&.to_i,
      student.user&.updated_at&.to_i,
      survey.id,
      survey.updated_at&.to_i,
      advisor&.advisor_id,
      advisor&.updated_at&.to_i,
      advisor&.user&.updated_at&.to_i,
      responses.size,
      response_updated.max,
      response_created.max,
      feedback_entries.size,
      feedback_updated.max,
      feedback_created.max,
      feedback_entries.map(&:id).max,
      @survey_response.status.to_s,
      @survey_response.completion_date&.to_i
    ]

    Digest::SHA256.hexdigest(components.map { |value| value.present? ? value : "nil" }.join("|"))
  end

  private

  def ensure_dependency!
    raise MissingDependency, "WickedPdf not loaded" unless defined?(WickedPdf)
  end

  def cache_enabled?
    @cache_enabled
  end

  def logger
    @logger || Rails.logger
  end

  def render_with_cache
    pdf_tempfile = nil
    fingerprint = cache_fingerprint

    cache_entry = CompositeReportCache.fetch(cache_key, fingerprint, ttl: CACHE_TTL) do
      html = render_html
      log_html_size(html)

      pdf_tempfile = build_pdf_file(html)
      pdf_tempfile.close
      pdf_tempfile.path
    end

    unless cache_entry&.path && File.exist?(cache_entry.path)
      raise GenerationError, "Composite PDF generation failed"
    end

    size_bytes = cache_entry.size_bytes || File.size?(cache_entry.path)
    log_pdf_size(size_bytes, cache_entry.cached? ? "cache" : "fresh")

    Result.new(path: cache_entry.path, cached: cache_entry.cached?, size_bytes: size_bytes)
  ensure
    cleanup_tempfile(pdf_tempfile)
  end

  def render_without_cache
    pdf_tempfile = nil
    result_ready = false

    html = render_html
    log_html_size(html)

    pdf_tempfile = build_pdf_file(html)
    pdf_path = pdf_tempfile.path
    pdf_tempfile.flush if pdf_tempfile.respond_to?(:flush)
    pdf_tempfile.close

    size_bytes = File.size?(pdf_path)
    log_pdf_size(size_bytes, "fresh")

    result = Result.new(
      path: pdf_path,
      cached: false,
      size_bytes: size_bytes,
      cleanup: -> { cleanup_tempfile(pdf_tempfile) }
    )
    result_ready = true
    result
  ensure
    cleanup_tempfile(pdf_tempfile) unless result_ready
  end

  def cache_key
    "composite-report:#{@survey_response.id}"
  end

  def render_html
    timestamp = Time.current
    ApplicationController.render(
      template: "composite_reports/show",
      layout: "pdf",
      locals: view_locals(timestamp),
      formats: [ :html ]
    )
  end

  def build_pdf_file(html)
    zoom = ENV.fetch("WKHTMLTOPDF_ZOOM", "1.0")
    dpi = ENV.fetch("WKHTMLTOPDF_DPI", "192")
    WickedPdf.new.pdf_from_string(
      html,
      encoding: "UTF-8",
      viewport_size: "1024x768",
      margin: { top: 10, bottom: 12, left: 8, right: 8 },
      disable_smart_shrinking: true,
      load_error_handling: "ignore",
      load_media_error_handling: "ignore",
      no_stop_slow_scripts: true,
      print_media_type: true,
      quiet: true,
      extra: [
        "--enable-local-file-access",
        "--dpi", dpi.to_s,
        "--image-dpi", "300",
        "--image-quality", "95",
        "--zoom", zoom.to_s,
        "--no-outline",
        "--javascript-delay", "500"
      ],
      return_file: true,
      delete_temporary_files: true
    )
  end

  def view_locals(generated_at)
    {
      survey_response: @survey_response,
      student: student,
      advisor: advisor,
      survey: survey,
      categories: categories,
      question_responses: question_responses,
      responses_by_question: responses_by_question,
      answers_by_question: answers_by_question,
      feedbacks_by_category: feedbacks_by_category,
      feedback_submission_by_advisor: feedback_submission_by_advisor,
      feedback_summary: feedback_summary,
      evidence_history_by_category: evidence_history_by_category,
      grade_derived_competencies: GradeImports::DerivedScorebook.for_student(student),
      generated_at: generated_at,
      answered_count: answered_count,
      total_questions: total_questions,
      required_answered_count: required_answered_count,
      required_total_questions: required_total_questions,
      progress_summary: progress_summary
    }
  end

  def student
    @student ||= @survey_response.student
  end

  def advisor
    @advisor ||= @survey_response.advisor
  end

  def survey
    @survey ||= @survey_response.survey
  end

  def categories
    scope = survey.categories.includes(:questions, :section)
    @categories ||= if Category.column_names.include?("position")
                     scope.order(:position, :id).to_a
    else
                     scope.order(:id).to_a
    end
  end

  def question_responses
    @question_responses ||= @survey_response.question_responses.to_a
  end

  def answers_by_question
    @answers_by_question ||= @survey_response.answers
  end

  def responses_by_question
    @responses_by_question ||= question_responses.index_by(&:question_id)
  end

  def feedback_scope
    scope = Feedback.where(student_id: student.student_id, survey_id: survey.id).includes(:category, :advisor)
    return scope unless viewer_mode == :student

    submitted_advisor_ids = AdvisorFeedbackSubmission
      .submitted
      .where(student_id: student.student_id, survey_id: survey.id)
      .pluck(:advisor_id)

    scope.where(advisor_id: submitted_advisor_ids)
  end

  def feedback_submission_by_advisor
    @feedback_submission_by_advisor ||= AdvisorFeedbackSubmission
      .where(student_id: student.student_id, survey_id: survey.id)
      .index_by(&:advisor_id)
  end

  def feedback_records
    @feedback_records ||= feedback_scope.to_a
  end

  def feedbacks_by_category
    @feedbacks_by_category ||= feedback_records.group_by(&:category_id).transform_values do |entries|
      entries.sort_by { |entry| entry.updated_at || entry.created_at || Time.at(0) }.reverse
    end
  end

  def feedback_summary
    @feedback_summary ||= begin
      entries = feedback_records
      scores = entries.map(&:average_score).compact.map(&:to_f)
      {
        total_entries: entries.size,
        scored_entries: scores.size,
        average_score: scores.any? ? (scores.sum / scores.size).round(2) : nil,
        latest_feedback_at: entries.filter_map { |entry| entry.updated_at || entry.created_at }.max
      }
    end
  end

  def evidence_history_by_category
    @evidence_history_by_category ||= begin
      history = @survey_response.evidence_history_by_category
      limit = MAX_EVIDENCE_HISTORY
      return history if limit.to_i <= 0

      history.transform_values { |entries| entries.first(limit) }
    end
  end

  def answered_count
    progress_summary[:answered_total]
  end

  def total_questions
    progress_summary[:total_questions]
  end

  def required_answered_count
    progress_summary[:answered_required]
  end

  def required_total_questions
    progress_summary[:total_required]
  end

  def progress_summary
    @progress_summary ||= @survey_response.progress_summary
  end

  def viewer_mode
    @viewer_mode
  end

  def log_html_size(html)
    html_size = html.to_s.bytesize
    logger.info("[CompositeReportGenerator] HTML payload size=#{number_to_human_size(html_size)} for SurveyResponse=#{@survey_response.id}")
  end

  def log_pdf_size(size_bytes, origin)
    human_size = number_to_human_size(size_bytes.to_i)
    logger.info("[CompositeReportGenerator] PDF payload size=#{human_size} (#{origin}) for SurveyResponse=#{@survey_response.id}")
  end

  def cleanup_tempfile(tempfile)
    return unless tempfile

    tempfile.close!
  rescue Errno::ENOENT, IOError
       # File already moved or deleted.
  end
end
