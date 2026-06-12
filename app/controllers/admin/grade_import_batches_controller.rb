require "csv"
require "axlsx"

class Admin::GradeImportBatchesController < Admin::BaseController
  IMPORT_EXTENSIONS = GradeImports::FileUploadRouter::SUPPORTED_EXTENSIONS
  SAMPLE_IMPORT_KINDS = %w[success duplicate pending_match bad_values bad_mapping].freeze
  WORKFLOW_FILTERS = {
    "preview" => "Preview",
    "committed" => "Committed",
    "rolled_back" => "Rolled back",
    "finalized" => "Finalized"
  }.freeze

  before_action :set_batch, only: %i[
    show approve commit reupload rollback recommit rebuild_ratings finalize semester destroy
    export_ratings export_evidence error_report correction_file update_pending_row update_pending_row_group update_evidence
  ]

  def index
    @batch_filters = grade_import_batch_filter_params
    @workflow_filter_options = WORKFLOW_FILTERS
    @status_filter_options = GradeImportBatch::STATUSES.index_with(&:humanize)
    @semester_filter_options = ProgramSemester.ordered
    @uploader_filter_options = User.where(id: GradeImportBatch.select(:uploaded_by_id).distinct).order(:email)
    filtered_batches = filtered_grade_import_batches
    @target_attainment_by_semester_course = target_attainment_by_semester_course(filtered_batches)
    @batches = filtered_batches
                 .includes(:uploaded_by, :program_semester, :grade_import_files)
                 .order(created_at: :desc)
                 .limit(100)
  end

  def new
  end

  def sample
    kind = params[:kind].to_s
    unless SAMPLE_IMPORT_KINDS.include?(kind)
      redirect_to new_admin_grade_import_batch_path, alert: "Unknown sample import file." and return
    end

    if kind == "bad_mapping"
      send_data sample_bad_mapping_workbook,
                filename: "sample-grade-import-bad-mapping.xlsx",
                type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    else
      send_data sample_direct_competency_csv(kind),
                filename: "sample-grade-import-#{kind.tr('_', '-')}-PHPM_631_600.csv",
                type: "text/csv"
    end
  end

  def create
    files = selected_import_files

    if files.blank?
      redirect_to new_admin_grade_import_batch_path, alert: "Please choose at least one .xlsx, .xlsm, or .csv file." and return
    end

    program_semester_id = required_program_semester_id
    unless program_semester_id
      redirect_to new_admin_grade_import_batch_path, alert: "Choose a program semester for this batch before importing. Course sections are semester-specific." and return
    end

    @batch = GradeImportBatch.create!(
      uploaded_by: current_user,
      program_semester_id: program_semester_id,
      summary: {
        "dry_run" => dry_run_requested?,
        "import_notes" => grade_import_batch_params[:import_notes].to_s.strip.presence
      }.compact
    )

    GradeImports::BatchProcessor.new(batch: @batch, files: files, dry_run: dry_run_requested?).call
    record_grade_import_activity!(
      "upload",
      "Uploaded grade import batch ##{@batch.id} as #{dry_run_requested? ? 'a preview' : 'a committed import'}.",
      file_names: files.map { |file| file.original_filename.to_s }
    )
    notify_advisors_of_course_data_update!("uploaded") if @batch.reportable?
    notify_admins_of_grade_import_review_if_needed!("upload")
    notify_admins_of_missing_grade_import_semester! if @batch.reportable?

    notice = dry_run_requested? ? "Preview completed. Review the results before committing." : "Grade import batch processed."
    redirect_to admin_grade_import_batch_path(@batch), notice: notice
  rescue StandardError => e
    Rails.logger.error("[Admin::GradeImportBatchesController#create] #{e.class}: #{e.message}")
    if @batch&.persisted?
      @batch.update(status: "failed", completed_at: Time.current, summary: { error: e.message })
      notify_admins_of_grade_import_failure!(e.message)
      redirect_to admin_grade_import_batch_path(@batch), alert: "Batch failed: #{e.message}"
    else
      redirect_to new_admin_grade_import_batch_path, alert: "Batch failed: #{e.message}"
    end
  end

  def show
    @files = @batch.grade_import_files.order(:id)
    @ratings = @batch.grade_competency_ratings.includes(student: :user).order(:competency_title, :student_id).limit(500)
    @evidences = @batch.grade_competency_evidences
                     .includes(:grade_import_file)
                     .order(:grade_import_file_id, :row_number, :id)
                     .limit(2_000)
    @pending_rows = @batch.grade_import_pending_rows
                          .pending_student_match
                          .includes(:grade_import_file, :matched_student)
                          .order(:grade_import_file_id, :row_number, :id)
                          .limit(2_000)
    @pending_competency_counts_by_file = @batch.grade_import_pending_rows.pending_student_match.group(:grade_import_file_id).count
    @pending_student_counts_by_file = pending_student_counts_by_file
    @match_rate = match_rate_for(@files)
    @failed_row_count = @files.sum(&:error_rows)
    @processed_row_count = @files.sum(&:imported_rows)
    @pending_row_count = @batch.grade_import_pending_rows.pending_student_match.count
    @duplicate_warnings = @files.sum { |file| file.parsed_content.dig("grade_sheet_debug", "duplicate_warning_count").to_i }
    @duplicate_upload_warnings = @files.sum { |file| file.parsed_content["duplicate_file_upload_count"].to_i }
    @validation_summary = validation_summary_for(@files)
    @target_warning_summary = target_warning_summary
    @target_attainment_by_course = target_attainment_by_course
    @target_attainment_by_course_and_competency = target_attainment_by_course_and_competency
    @student_match_options = student_match_options
    @approval_confirmation_sections = approval_confirmation_sections(
      files: @files,
      pending_rows: @pending_rows,
      target_warning_summary: @target_warning_summary
    )
    @approval_confirmation_message = approval_confirmation_message(sections: @approval_confirmation_sections)
  end

  def approve
    unless @batch.dry_run?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Only previews can be approved for commit." and return
    end

    if course_code_issues_present?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Fix the course code issues before approving. Each imported course needs a 4-letter department code, 3-digit course number, and 3-digit section number." and return
    end

    unless @batch.needs_admin_approval? || target_warning_summary[:requires_review]
      redirect_to admin_grade_import_batch_path(@batch), alert: "Only previews with failed, pending, or target-warning rows need admin approval." and return
    end

    approved_summary = @batch.summary.merge(
      "admin_approved_at" => Time.current.iso8601,
      "admin_approved_by" => current_user.email
    )

    @batch.update!(summary: approved_summary)
    record_grade_import_activity!("approve", "Approved grade import preview ##{@batch.id} for commit.")

    redirect_to admin_grade_import_batch_path(@batch),
                notice: "Preview approved. It can now be committed."
  end

  def commit
    unless @batch.program_semester_id.present?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Assign a program semester before committing. Course sections are semester-specific." and return
    end

    if course_code_issues_present?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Fix the course code issues before committing. Each imported course needs a 4-letter department code, 3-digit course number, and 3-digit section number." and return
    end

    if (@batch.needs_admin_approval? || target_warning_summary[:requires_review]) && !@batch.admin_approved?
      redirect_to admin_grade_import_batch_path(@batch),
                  alert: "Review and approve this preview before committing because it has failed, pending, or target-warning rows." and return
    end

    unless @batch.committable_dry_run?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Only completed previews can be committed." and return
    end

    committed_summary = @batch.summary.merge(
      "dry_run" => false,
      "committed_at" => Time.current.iso8601,
      "committed_by" => current_user.email
    )

    @batch.update!(summary: committed_summary)
    record_grade_import_activity!("commit", "Committed grade import preview ##{@batch.id} so its course competency data is reportable.")
    notify_advisors_of_course_data_update!("published")
    notify_admins_of_missing_grade_import_semester!

    redirect_to admin_grade_import_batch_path(@batch), notice: "Preview committed. This batch now appears in reportable course competency views."
  end

  def reupload
    if @batch.finalized?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch is finalized and locked. Files cannot be re-uploaded." and return
    end

    unless @batch.dry_run?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Only preview batches can be re-uploaded before commit." and return
    end

    unless @batch.program_semester_id.present?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Assign a program semester before re-uploading corrected files. Course sections are semester-specific." and return
    end

    files = selected_import_files
    if files.blank?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Please choose at least one corrected .xlsx, .xlsm, or .csv file to re-upload." and return
    end

    @batch.update!(summary: reupload_review_reset_summary)
    GradeImports::BatchProcessor.new(
      batch: @batch,
      files: files,
      dry_run: true,
      replace_existing_files: true
    ).call

    @batch.update!(
      summary: @batch.summary.merge(
        "last_reuploaded_at" => Time.current.iso8601,
        "last_reuploaded_by" => current_user.email,
        "last_reuploaded_file_names" => files.map { |file| file.original_filename.to_s }
      )
    )
    record_grade_import_activity!(
      "reupload",
      "Re-uploaded corrected files for grade import preview ##{@batch.id}.",
      file_names: files.map { |file| file.original_filename.to_s }
    )
    notify_admins_of_grade_import_review_if_needed!("reupload")

    redirect_to admin_grade_import_batch_path(@batch), notice: "Corrected file re-uploaded. Matching filenames replaced previous rows in this batch."
  rescue StandardError => e
    Rails.logger.error("[Admin::GradeImportBatchesController#reupload] #{e.class}: #{e.message}")
    notify_admins_of_grade_import_failure!(e.message) if @batch&.persisted?
    redirect_to admin_grade_import_batch_path(@batch), alert: "Re-upload failed: #{e.message}"
  end

  def rollback
    if @batch.finalized?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch is finalized and locked. It cannot be rolled back." and return
    end

    if @batch.rolled_back?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch has already been rolled back." and return
    end

    @batch.update!(
      status: "rolled_back",
      summary: @batch.summary.merge(
        "previous_status" => @batch.status,
        "rolled_back_at" => Time.current.iso8601,
        "rolled_back_by" => current_user.email
      )
    )
    record_grade_import_activity!("rollback", "Rolled back grade import batch ##{@batch.id}; its course competency data is hidden from reportable views.")

    redirect_to admin_grade_import_batch_path(@batch), notice: "Batch rolled back. It is now hidden from downstream views but can be recommitted later."
  end

  def recommit
    unless @batch.program_semester_id.present?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Assign a program semester before recommitting. Course sections are semester-specific." and return
    end

    unless @batch.recommittable_rollback?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Only rolled-back committed batches with preserved import data can be recommitted." and return
    end

    restored_status = @batch.summary["previous_status"].presence_in(%w[completed completed_with_errors]) || "completed"

    @batch.update!(
      status: restored_status,
      summary: @batch.summary.merge(
        "recommitted_at" => Time.current.iso8601,
        "recommitted_by" => current_user.email
      ).except("rolled_back_at", "rolled_back_by")
    )
    record_grade_import_activity!("recommit", "Recommitted grade import batch ##{@batch.id}; its course competency data is reportable again.")
    notify_advisors_of_course_data_update!("re-published")
    notify_admins_of_missing_grade_import_semester!

    redirect_to admin_grade_import_batch_path(@batch), notice: "Batch recommitted. Its course competency data is visible in the app again."
  end

  def rebuild_ratings
    if @batch.finalized?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch is finalized and locked. Ratings cannot be rebuilt." and return
    end

    rebuild_batch_ratings!
    record_grade_import_activity!("rebuild_ratings", "Rebuilt derived ratings for grade import batch ##{@batch.id}.")

    redirect_to admin_grade_import_batch_path(@batch), notice: "Derived competency ratings were rebuilt from the current evidence rows."
  end

  def finalize
    unless @batch.finalizable?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Only committed reportable batches can be finalized." and return
    end

    @batch.update!(
      summary: @batch.summary.merge(
        "finalized_at" => Time.current.iso8601,
        "finalized_by" => current_user.email
      )
    )
    record_grade_import_activity!("finalize", "Finalized and locked grade import batch ##{@batch.id}.")

    redirect_to admin_grade_import_batch_path(@batch), notice: "Batch finalized and locked after review."
  end

  def semester
    if @batch.finalized?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch is finalized and locked. Semester cannot be changed." and return
    end

    previous_semester_id = @batch.program_semester_id
    program_semester_id = required_program_semester_id
    unless program_semester_id
      redirect_to admin_grade_import_batch_path(@batch), alert: "Choose a program semester. Grade import batches cannot be left without one." and return
    end

    @batch.update!(program_semester_id: program_semester_id)
    record_grade_import_activity!(
      "semester_change",
      "Changed semester assignment for grade import batch ##{@batch.id}.",
      previous_program_semester_id: previous_semester_id,
      new_program_semester_id: @batch.program_semester_id,
      new_program_semester_name: @batch.program_semester&.name
    )

    redirect_to admin_grade_import_batch_path(@batch), notice: "Batch semester updated to #{@batch.program_semester.name}."
  end

  def destroy
    if @batch.finalized?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch is finalized and locked. It cannot be deleted." and return
    end

    batch_id = @batch.id
    record_grade_import_activity!("delete", "Deleted grade import batch ##{batch_id} and its imported rows.")
    @batch.destroy!

    redirect_to admin_grade_import_batches_path, notice: "Grade import batch ##{batch_id} was deleted. Its files, evidence, ratings, pending rows, and duplicate fingerprints were removed."
  end

  def export_ratings
    respond_to do |format|
      format.csv do
        record_export_audit!(
          export_type: "grade_import_derived_ratings_csv",
          description: "Exported derived ratings CSV for grade import batch ##{@batch.id}.",
          subject: @batch,
          metadata: { batch_id: @batch.id }
        )
        send_data ratings_csv,
                  filename: "grade-import-batch-#{@batch.id}-derived-ratings.csv",
                  type: "text/csv"
      end
      format.any { head :not_acceptable }
    end
  end

  def export_evidence
    record_export_audit!(
      export_type: "grade_import_evidence_rows_csv",
      description: "Exported row-level evidence CSV for grade import batch ##{@batch.id}.",
      subject: @batch,
      metadata: { batch_id: @batch.id }
    )
    send_data evidence_csv,
              filename: "grade-import-batch-#{@batch.id}-evidence-rows.csv",
              type: "text/csv"
  end

  def error_report
    record_export_audit!(
      export_type: "grade_import_error_report_csv",
      description: "Exported error report CSV for grade import batch ##{@batch.id}.",
      subject: @batch,
      metadata: { batch_id: @batch.id }
    )
    send_data error_report_csv,
              filename: "grade-import-batch-#{@batch.id}-errors.csv",
              type: "text/csv"
  end

  def correction_file
    record_export_audit!(
      export_type: "grade_import_correction_file_csv",
      description: "Exported correction file CSV for grade import batch ##{@batch.id}.",
      subject: @batch,
      metadata: { batch_id: @batch.id }
    )
    send_data correction_file_csv,
              filename: "grade-import-batch-#{@batch.id}-corrections.csv",
              type: "text/csv"
  end

  def update_pending_row
    if @batch.finalized?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch is finalized and locked. Pending rows cannot be changed." and return
    end

    row = @batch.grade_import_pending_rows.find(params[:pending_row_id])
    row.update!(pending_row_params)

    if params.dig(:grade_import_pending_row, :matched_student_id).present?
      student = Student.includes(:user).find(params.dig(:grade_import_pending_row, :matched_student_id))
      reconcile_pending_row!(row, student)
      rebuild_batch_ratings!
      record_grade_import_activity!(
        "pending_row_match",
        "Matched a pending grade import row in batch ##{@batch.id}.",
        pending_row_id: row.id,
        matched_student_id: student.student_id
      )
      redirect_to admin_grade_import_batch_path(@batch), notice: "Pending row matched to #{student.user&.display_name || student.student_id} and ratings rebuilt."
    else
      record_grade_import_activity!(
        "pending_row_update",
        "Updated a pending grade import row in batch ##{@batch.id}.",
        pending_row_id: row.id
      )
      redirect_to admin_grade_import_batch_path(@batch), notice: "Pending row correction saved."
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    redirect_to admin_grade_import_batch_path(@batch), alert: "Could not update pending row: #{e.message}"
  end

  def update_pending_row_group
    if @batch.finalized?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch is finalized and locked. Pending rows cannot be changed." and return
    end

    rows = @batch.grade_import_pending_rows
                 .pending_student_match
                 .where(id: normalized_pending_row_ids)
                 .order(:grade_import_file_id, :row_number, :id)
                 .to_a

    if rows.blank?
      redirect_to admin_grade_import_batch_path(@batch), alert: "No pending rows were selected for update." and return
    end

    shared_attrs = pending_row_group_params
    row_updates = normalized_pending_row_updates
    matched_student_id = shared_attrs.delete(:matched_student_id).presence
    matched_student = matched_student_id.present? ? Student.includes(:user).find(matched_student_id) : nil

    ActiveRecord::Base.transaction do
      rows.each do |row|
        row_attrs = shared_attrs.merge(row_updates.fetch(row.id.to_s, {}))
        row.update!(normalize_blank_level_params(row_attrs))
        reconcile_pending_row!(row, matched_student) if matched_student.present?
      end
    end

    rebuild_batch_ratings! if matched_student.present?
    record_grade_import_activity!(
      matched_student.present? ? "pending_row_group_match" : "pending_row_group_update",
      matched_student.present? ? "Matched #{rows.size} pending grade import rows in batch ##{@batch.id}." : "Updated #{rows.size} pending grade import rows in batch ##{@batch.id}.",
      pending_row_ids: rows.map(&:id),
      matched_student_id: matched_student&.student_id
    )

    notice = if matched_student.present?
      "Matched #{rows.size} pending rows to #{matched_student.user&.display_name || matched_student.student_id} and rebuilt ratings."
    else
      "Saved corrections for #{rows.size} pending rows."
    end

    redirect_to admin_grade_import_batch_path(@batch), notice: notice
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    redirect_to admin_grade_import_batch_path(@batch), alert: "Could not update pending rows: #{e.message}"
  end

  def update_evidence
    if @batch.finalized?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch is finalized and locked. Evidence rows cannot be changed." and return
    end

    evidence = @batch.grade_competency_evidences.find(params[:evidence_id])
    evidence.update!(evidence_params)
    rebuild_batch_ratings!
    record_grade_import_activity!(
      "correct_evidence",
      "Corrected an imported evidence row in grade import batch ##{@batch.id}.",
      evidence_id: evidence.id,
      course_code: evidence.course_code,
      competency_title: evidence.competency_title
    )

    redirect_to admin_grade_import_batch_path(@batch), notice: "Evidence row corrected and derived ratings rebuilt."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    redirect_to admin_grade_import_batch_path(@batch), alert: "Could not update evidence row: #{e.message}"
  end

  private

  def set_batch
    @batch = GradeImportBatch.find(params[:id])
  end

  def dry_run_requested?
    ActiveModel::Type::Boolean.new.cast(params[:dry_run])
  end

  def grade_import_batch_params
    params.permit(:program_semester_id, :import_notes)
  end

  def required_program_semester_id
    semester_id = grade_import_batch_params[:program_semester_id].presence
    return unless semester_id

    ProgramSemester.exists?(semester_id) ? semester_id : nil
  end

  def grade_import_batch_filter_params
    params.permit(:q, :status, :workflow, :program_semester_id, :uploaded_by_id).to_h
  end

  def filtered_grade_import_batches
    scope = GradeImportBatch.all

    if @batch_filters["status"].present? && GradeImportBatch::STATUSES.include?(@batch_filters["status"])
      scope = scope.where(status: @batch_filters["status"])
    end

    scope = apply_grade_import_workflow_filter(scope, @batch_filters["workflow"])
    scope = apply_grade_import_semester_filter(scope, @batch_filters["program_semester_id"])
    scope = apply_grade_import_uploader_filter(scope, @batch_filters["uploaded_by_id"])
    scope = apply_grade_import_search_filter(scope, @batch_filters["q"])

    scope
  end

  def apply_grade_import_workflow_filter(scope, workflow)
    case workflow
    when "preview"
      scope.where("COALESCE(grade_import_batches.summary ->> 'dry_run', 'false') = 'true'").where.not(status: "rolled_back")
    when "committed"
      scope.where("COALESCE(grade_import_batches.summary ->> 'dry_run', 'true') = 'false'")
           .where(status: %w[completed completed_with_errors])
    when "rolled_back"
      scope.where(status: "rolled_back")
    when "finalized"
      scope.where("grade_import_batches.summary ->> 'finalized_at' IS NOT NULL")
    else
      scope
    end
  end

  def apply_grade_import_semester_filter(scope, semester_id)
    return scope if semester_id.blank?
    return scope.where(program_semester_id: nil) if semester_id == "none"

    scope.where(program_semester_id: semester_id)
  end

  def apply_grade_import_uploader_filter(scope, uploader_id)
    return scope if uploader_id.blank?

    scope.where(uploaded_by_id: uploader_id)
  end

  def apply_grade_import_search_filter(scope, query)
    query = query.to_s.strip
    return scope if query.blank?

    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
    scope
      .left_outer_joins(:grade_import_files, :grade_competency_evidences, :grade_import_pending_rows)
      .where(
        "grade_import_files.file_name ILIKE :query OR " \
        "grade_competency_evidences.course_code ILIKE :query OR " \
        "grade_import_pending_rows.course_code ILIKE :query OR " \
        "grade_import_batches.summary ->> 'import_notes' ILIKE :query",
        query: pattern
      )
      .distinct
  end

  def selected_import_files
    files = Array(params[:files]).compact_blank + Array(params[:folder_files]).compact_blank
    files.select { |file| IMPORT_EXTENSIONS.include?(File.extname(file.original_filename.to_s).downcase) }
  end

  def reupload_review_reset_summary
    @batch.summary.except(
      "admin_approved_at",
      "admin_approved_by",
      "committed_at",
      "committed_by",
      "error"
    ).merge("dry_run" => true)
  end

  def pending_row_params
    raw = params.require(:grade_import_pending_row).permit(
      :student_identifier,
      :student_identifier_type,
      :student_name,
      :student_uin,
      :student_email,
      :course_code,
      :assignment_name,
      :competency_title,
      :raw_grade,
      :mapped_level,
      :course_target_level
    )

    normalize_blank_level_params(raw)
  end

  def pending_row_group_params
    raw_params = params[:grade_import_pending_row_group] || {}
    raw_params = ActionController::Parameters.new(raw_params) unless raw_params.respond_to?(:permit)

    raw = raw_params.permit(
      :matched_student_id,
      :student_identifier,
      :student_identifier_type,
      :student_name,
      :student_uin,
      :student_email
    )

    raw[:student_identifier_type] = raw[:student_identifier_type].presence if raw.key?(:student_identifier_type)
    raw
  end

  def pending_student_counts_by_file
    counts = Hash.new(0)
    seen = Hash.new { |hash, key| hash[key] = {} }

    @batch.grade_import_pending_rows
          .pending_student_match
          .select(:id, :grade_import_file_id, :student_identifier_type, :student_identifier, :student_uin, :student_email, :student_name)
          .find_each do |row|
      identity = row.student_uin.presence ||
                 row.student_email.presence ||
                 row.student_identifier.presence ||
                 row.student_name.presence ||
                 "pending-row-#{row.id}"
      identity_key = [
        row.student_identifier_type.presence || "student",
        identity.to_s.downcase.strip
      ]

      next if seen[row.grade_import_file_id][identity_key]

      seen[row.grade_import_file_id][identity_key] = true
      counts[row.grade_import_file_id] += 1
    end

    counts
  end

  def normalized_pending_row_ids
    Array(params[:pending_row_ids]).filter_map do |value|
      id = value.to_s.strip.to_i
      id.positive? ? id : nil
    end.uniq
  end

  def normalized_pending_row_updates
    updates = params.fetch(:pending_rows, {})
    updates = updates.to_unsafe_h if updates.respond_to?(:to_unsafe_h)

    updates.each_with_object({}) do |(row_id, attrs), memo|
      permitted = ActionController::Parameters.new(attrs || {}).permit(
        :course_code,
        :assignment_name,
        :competency_title,
        :raw_grade,
        :mapped_level,
        :course_target_level
      )
      memo[row_id.to_s] = normalize_blank_level_params(permitted)
    end
  end

  def evidence_params
    raw = params.require(:grade_competency_evidence).permit(
      :course_code,
      :assignment_name,
      :competency_title,
      :raw_grade,
      :mapped_level,
      :course_target_level
    )

    normalize_blank_level_params(raw)
  end

  def normalize_blank_level_params(attrs)
    attrs[:course_target_level] = nil if attrs.key?(:course_target_level) && attrs[:course_target_level].blank?
    attrs
  end

  def match_rate_for(files)
    total_attempted = files.sum { |file| file.imported_rows.to_i + file.pending_rows.to_i + file.error_rows.to_i }
    return nil if total_attempted.zero?

    ((files.sum(&:imported_rows).to_f / total_attempted) * 100).round(1)
  end

  def target_attainment_by_course
    GradeImports::TargetAttainmentReport.new(@batch.grade_competency_evidences).by_course
  end

  def target_attainment_by_course_and_competency
    GradeImports::TargetAttainmentReport.new(@batch.grade_competency_evidences).by_course_and_competency
  end

  def target_attainment_by_semester_course(batch_scope)
    batch_ids = batch_scope.reportable.select(:id)
    evidence_scope = GradeCompetencyEvidence.where(grade_import_batch_id: batch_ids)

    GradeImports::TargetAttainmentReport.new(evidence_scope).by_semester_course_and_competency.first(100)
  end

  def record_grade_import_activity!(import_action, description, metadata = {})
    return unless current_user && @batch

    AdminActivityLog.record!(
      admin: current_user,
      action: "grade_import_action",
      description: description,
      subject: @batch,
      metadata: grade_import_activity_metadata(import_action).merge(metadata.compact)
    )
  rescue StandardError => e
    Rails.logger.warn("[GradeImportAudit] Failed to record import activity: #{e.class}: #{e.message}")
  end

  def notify_advisors_of_course_data_update!(action_label)
    advisor_counts = Student
      .where(student_id: @batch.grade_competency_evidences.select(:student_id))
      .where.not(advisor_id: nil)
      .group(:advisor_id)
      .count
    return if advisor_counts.blank?

    User.advisors.where(id: advisor_counts.keys).find_each do |advisor_user|
      count = advisor_counts[advisor_user.id].to_i
      noun = count == 1 ? "advisee" : "advisees"
      semester_label = @batch.program_semester&.name
      semester_phrase = semester_label.present? ? " for #{semester_label}" : ""
      notification = Notification.deliver!(
        user: advisor_user,
        title: "Advisee Course Competency Data Updated",
        message: "Course competency data was #{action_label}#{semester_phrase} for #{count} #{noun} you advise.",
        notifiable: @batch,
        event_key: "advisee.course_data.updated",
        dedupe_key: "advisee.course_data.updated:batch:#{@batch.id}:advisor:#{advisor_user.id}:action:#{action_label}",
        metadata: {
          batch_id: @batch.id,
          advisor_id: advisor_user.id,
          advisee_count: count,
          action: action_label,
          program_semester_id: @batch.program_semester_id,
          program_semester_name: semester_label
        }
      )
      NotificationEmailDeliveryJob.perform_later(notification_id: notification.id)
    end
  rescue StandardError => e
    Rails.logger.warn("[GradeImportNotifications] Failed advisor notification for batch #{@batch&.id}: #{e.class}: #{e.message}")
  end

  def notify_admins_of_grade_import_review_if_needed!(action_label)
    summary = grade_import_attention_summary
    return unless summary[:needs_review]

    reasons = summary[:reasons].presence || [ "review is required before this batch can be committed" ]
    notify_admins_of_grade_import_event!(
      event_key: "grade_import.review_needed",
      title: "Grade Import Needs Review",
      message: "Grade import batch ##{@batch.id} needs admin review after #{action_label}: #{reasons.to_sentence}.",
      metadata: grade_import_attention_metadata(summary, action_label: action_label)
    )
  end

  def notify_admins_of_grade_import_failure!(error_message)
    summary = grade_import_attention_summary(error_message: error_message)
    notify_admins_of_grade_import_event!(
      event_key: "grade_import.failed",
      title: "Grade Import Failed",
      message: "Grade import batch ##{@batch.id} failed: #{error_message}.",
      metadata: grade_import_attention_metadata(summary, action_label: "failure", error_message: error_message)
    )
  end

  def notify_admins_of_missing_grade_import_semester!
    return unless @batch&.reportable?
    return if @batch.program_semester_id.present?

    notify_admins_of_grade_import_event!(
      event_key: "grade_import.missing_semester",
      title: "Grade Import Missing Semester",
      message: "Grade import batch ##{@batch.id} is reportable but does not have a semester assigned. Add a semester so reports and student views filter correctly.",
      metadata: {
        batch_id: @batch.id,
        status: @batch.status,
        dry_run: @batch.dry_run?,
        reportable: @batch.reportable?,
        program_semester_id: @batch.program_semester_id
      }
    )
  end

  def notify_admins_of_grade_import_event!(event_key:, title:, message:, metadata:)
    User.admins.find_each do |admin_user|
      notification = Notification.deliver!(
        user: admin_user,
        title: title,
        message: message,
        notifiable: @batch,
        event_key: event_key,
        dedupe_key: "#{event_key}:batch:#{@batch.id}:admin:#{admin_user.id}",
        metadata: metadata.merge(admin_id: admin_user.id)
      )
      NotificationEmailDeliveryJob.perform_later(notification_id: notification.id) if notification
    end
  rescue StandardError => e
    Rails.logger.warn("[GradeImportNotifications] Failed admin notification for batch #{@batch&.id}: #{e.class}: #{e.message}")
  end

  def grade_import_attention_summary(error_message: nil)
    files = @batch.grade_import_files.to_a
    target_counts = target_warning_summary.fetch(:counts, {})
    failed_file_count = files.count { |file| file.status == "failed" || Array(file.parse_errors).any? }
    failed_row_count = files.sum(&:error_rows)
    pending_row_count = @batch.grade_import_pending_rows.pending_student_match.count
    course_code_issue_count = target_counts[:course_code_issues].to_i
    missing_target_count = target_counts[:missing_course_targets].to_i
    mismatched_target_count = target_counts[:mismatched_configured_course_targets].to_i

    reasons = []
    reasons << error_message if error_message.present?
    reasons << count_phrase(failed_file_count, "failed file") if failed_file_count.positive?
    reasons << count_phrase(failed_row_count, "failed row") if failed_row_count.positive?
    reasons << count_phrase(pending_row_count, "pending student match", "pending student matches") if pending_row_count.positive?
    reasons << count_phrase(course_code_issue_count, "course code issue") if course_code_issue_count.positive?
    reasons << count_phrase(missing_target_count, "missing course target") if missing_target_count.positive?
    reasons << count_phrase(mismatched_target_count, "course target mismatch", "course target mismatches") if mismatched_target_count.positive?
    reasons << "preview completed with errors" if reasons.blank? && @batch.completed_with_errors?

    {
      needs_review: error_message.present? || @batch.failed? || @batch.needs_admin_approval? || target_warning_summary[:requires_review],
      reasons: reasons,
      failed_file_count: failed_file_count,
      failed_row_count: failed_row_count,
      pending_row_count: pending_row_count,
      course_code_issue_count: course_code_issue_count,
      missing_target_count: missing_target_count,
      mismatched_target_count: mismatched_target_count
    }
  end

  def grade_import_attention_metadata(summary, action_label:, error_message: nil)
    {
      batch_id: @batch.id,
      action: action_label,
      status: @batch.status,
      dry_run: @batch.dry_run?,
      reportable: @batch.reportable?,
      program_semester_id: @batch.program_semester_id,
      program_semester_name: @batch.program_semester&.name,
      failed_file_count: summary[:failed_file_count],
      failed_row_count: summary[:failed_row_count],
      pending_row_count: summary[:pending_row_count],
      course_code_issue_count: summary[:course_code_issue_count],
      missing_target_count: summary[:missing_target_count],
      mismatched_target_count: summary[:mismatched_target_count],
      reasons: summary[:reasons],
      error_message: error_message
    }.compact
  end

  def count_phrase(count, singular, plural = nil)
    "#{count} #{count == 1 ? singular : (plural || singular.pluralize)}"
  end

  def grade_import_activity_metadata(import_action)
    {
      import_action: import_action,
      batch_id: @batch.id,
      status: @batch.status,
      dry_run: @batch.dry_run?,
      finalized: @batch.finalized?,
      program_semester_id: @batch.program_semester_id,
      program_semester_name: @batch.program_semester&.name,
      file_count: @batch.grade_import_files.count,
      evidence_count: @batch.grade_competency_evidences.count,
      pending_count: @batch.grade_import_pending_rows.pending_student_match.count,
      rating_count: @batch.grade_competency_ratings.count,
      path: request.fullpath
    }
  end

  def ratings_export_rows
    grouped_provenance = @batch.grade_competency_evidences
                               .includes(:grade_import_file)
                               .group_by { |row| [ row.student_id, row.competency_title ] }

    rows = @batch.grade_competency_ratings
                 .includes(student: :user)
                 .order(:student_id, :competency_title)
                 .map do |rating|
      provenance_rows = Array(grouped_provenance[[ rating.student_id, rating.competency_title ]])
      course_codes = provenance_rows.map(&:course_code).compact_blank.uniq.sort
      assignment_names = provenance_rows.map(&:assignment_name).compact_blank.uniq.sort
      source_files = provenance_rows.map { |row| row.grade_import_file&.file_name }.compact_blank.uniq.sort
      course_target_levels = provenance_rows.map(&:course_target_level).compact.uniq.sort
      target_met_statuses = provenance_rows.map { |row| target_met_label(row.mapped_level, row.course_target_level) }.uniq.sort
      latest_updated_at = provenance_rows.map(&:updated_at).compact.max

      {
        student_id: rating.student_id,
        student_name: rating.student&.user&.name,
        student_email: rating.student&.user&.email,
        competency_title: rating.competency_title,
        aggregated_level: rating.aggregated_level,
        aggregation_rule: rating.aggregation_rule,
        evidence_count: rating.evidence_count,
        latest_updated_at: latest_updated_at&.iso8601,
        course_codes: course_codes.join("; "),
        assignment_names: assignment_names.join("; "),
        source_files: source_files.join("; "),
        course_target_levels: course_target_levels.join("; "),
        target_met_statuses: target_met_statuses.join("; "),
        provenance_details: provenance_rows.map do |row|
          [
            row.course_code,
            row.assignment_name,
            "raw=#{row.raw_grade}",
            "level=#{row.mapped_level}",
            row.course_target_level.present? ? "target=#{row.course_target_level}" : "target=none",
            "target_status=#{target_met_label(row.mapped_level, row.course_target_level)}",
            row.grade_import_file&.file_name
          ].compact.join(" | ")
        end.join(" || ")
      }
    end

    rows.sort_by do |row|
      [ row[:student_name].to_s.downcase, row[:student_id].to_i, row[:competency_title].to_s.downcase ]
    end
  end

  def ratings_csv
    CSV.generate(headers: true) do |csv|
      csv << [
        "Student ID",
        "Student Name",
        "Student Email",
        "Competency",
        "Aggregated Level",
        "Aggregation Rule",
        "Contributing Grades",
        "Latest Evidence Updated At",
        "Course Codes",
        "Assignments",
        "Source Files",
        "Course Target Levels",
        "Target Met Status",
        "Provenance Details"
      ]
      ratings_export_rows.each do |row|
        csv << row.values_at(
          :student_id,
          :student_name,
          :student_email,
          :competency_title,
          :aggregated_level,
          :aggregation_rule,
          :evidence_count,
          :latest_updated_at,
          :course_codes,
          :assignment_names,
          :source_files,
          :course_target_levels,
          :target_met_statuses,
          :provenance_details
        )
      end
    end
  end

  def evidence_csv
    CSV.generate(headers: true) do |csv|
      csv << [
        "Student Name",
        "Student UIN",
        "Student ID",
        "Student Email",
        "Course Code",
        "Competency",
        "Assessed Level",
        "Course Target Level",
        "Target Met?",
        "Raw Score",
        "Assignment",
        "Source File",
        "Source Row",
        "Last Updated"
      ]

      @batch.grade_competency_evidences
            .includes(:grade_import_file, student: :user)
            .order(:course_code, :student_id, :competency_title, :row_number, :id)
            .find_each do |row|
        csv << [
          row.student&.user&.name,
          row.student&.uin,
          row.student_id,
          row.student&.user&.email,
          row.course_code,
          row.competency_title,
          row.mapped_level,
          row.course_target_level,
          target_met_export_label(row.mapped_level, row.course_target_level),
          row.raw_grade,
          row.assignment_name,
          row.grade_import_file&.file_name,
          row.row_number,
          row.updated_at.strftime("%Y-%m-%d %H:%M:%S")
        ]
      end
    end
  end

  def error_report_csv
    CSV.generate(headers: true) do |csv|
      csv << [
        "file_name",
        "status",
        "type",
        "row",
        "column",
        "value",
        "expected",
        "received",
        "suggested_canonical_competency_title",
        "suggested_alias_string",
        "suggestion_score",
        "message",
        "correction_hint"
      ]
      @batch.grade_import_files.find_each do |file|
        Array(file.parse_errors).each do |error|
          csv << [
            file.file_name,
            file.status,
            error["type"].presence || "error",
            error["row"],
            error["column"],
            error["value"],
            error["expected"],
            error["received"],
            error["suggested_canonical_competency_title"],
            error["suggested_alias_string"],
            error["suggestion_score"],
            error["message"] || error.to_s,
            error["correction_hint"]
          ]
        end
      end
    end
  end

  def correction_file_csv
    CSV.generate(headers: true) do |csv|
      csv << [
        "Row Type",
        "Issue Type",
        "File Name",
        "Status",
        "Row Number",
        "Student Identifier Type",
        "Student Identifier",
        "Student Name",
        "Student UIN",
        "Student Email",
        "Course Code",
        "Assignment",
        "Competency",
        "Raw Grade",
        "Result Level",
        "Course Target Level",
        "Column",
        "Value",
        "Expected",
        "Received",
        "Suggested Canonical Competency",
        "Suggested Alias String",
        "Message",
        "Suggested Fix",
        "Correction Notes"
      ]

      @batch.grade_import_files.order(:id).find_each do |file|
        Array(file.parse_errors).each do |error|
          csv << [
            "failed",
            error["type"].presence || "error",
            file.file_name,
            file.status,
            error["row"],
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            error["column"],
            error["value"],
            error["expected"],
            error["received"],
            error["suggested_canonical_competency_title"],
            error["suggested_alias_string"],
            error["message"] || error.to_s,
            error["correction_hint"],
            nil
          ]
        end
      end

      @batch.grade_import_pending_rows.pending_student_match.includes(:grade_import_file).order(:grade_import_file_id, :row_number, :id).find_each do |row|
        csv << [
          "pending_student_match",
          "student_identifier",
          row.grade_import_file&.file_name,
          row.status,
          row.row_number,
          row.student_identifier_type,
          row.student_identifier,
          row.student_name,
          row.student_uin,
          row.student_email,
          row.course_code,
          row.assignment_name,
          row.competency_title,
          row.raw_grade,
          row.mapped_level,
          row.course_target_level,
          nil,
          nil,
          "matching student record",
          row.student_identifier,
          nil,
          nil,
          "Student could not be matched automatically. Add or correct UIN/email/name, then reconcile or re-upload.",
          "Update Student UIN/email/name or choose a matching student in the pending-row review section.",
          nil
        ]
      end
    end
  end

  def validation_summary_for(files)
    {
      total_files: files.size,
      failed_files: files.count { |file| file.status == "failed" },
      imported_rows: files.sum(&:imported_rows),
      pending_rows: files.sum(&:pending_rows),
      failed_rows: files.sum(&:error_rows),
      duplicate_file_uploads: files.sum { |file| file.parsed_content["duplicate_file_upload_count"].to_i },
      duplicate_rows: files.sum { |file| file.parsed_content.dig("grade_sheet_debug", "duplicate_warning_count").to_i }
    }
  end

  def target_warning_summary
    @target_warning_summary ||= GradeImports::TargetWarningAnalyzer.call(batch: @batch)
  end

  def course_code_issues_present?
    Array(target_warning_summary[:course_code_issues]).any?
  end

  def approval_confirmation_message(sections:)
    if sections.blank?
      return "Approve this preview? This confirms admin review and allows the preview to be committed."
    end

    [
      "Approve this preview?",
      "",
      "Review every listed item before approving. Nothing is hidden or summarized in this popup.",
      "",
      "Approving allows commit; it does not fix failed rows, pending matches, course-code issues, target warnings, or duplicate-file warnings."
    ].join("\n")
  end

  def approval_confirmation_sections(files:, pending_rows:, target_warning_summary:)
    sections = []
    failed_items = []
    duplicate_upload_items = []

    files.each do |file|
      Array(file.parse_errors).each do |error|
        failed_items << approval_parse_error_item(file, error)
      end

      Array(file.parsed_content["duplicate_file_uploads"]).each do |upload|
        duplicate_upload_items << approval_duplicate_upload_item(file, upload)
      end
    end

    pending_rows.each do |row|
      failed_items << approval_pending_invalid_uin_item(row) if invalid_student_uin?(row.student_uin)
    end

    sections << approval_section("Failed Values", failed_items)
    sections << approval_section("Duplicate Uploads", duplicate_upload_items)

    pending_student_items = approval_pending_student_items(pending_rows)
    sections << approval_section("Pending Student Matches", pending_student_items)

    course_code_issue_items = Array(target_warning_summary[:course_code_issues]).map { |row| approval_course_code_issue_item(row) }
    sections << approval_section("Course Code Issues", course_code_issue_items)

    missing_target_items = Array(target_warning_summary[:missing_course_targets]).map { |row| approval_missing_target_item(row) }
    sections << approval_section("Missing Course Targets", missing_target_items)

    mismatched_target_items = Array(target_warning_summary[:mismatched_configured_course_targets]).map { |row| approval_configured_target_mismatch_item(row) }
    sections << approval_section("Configured Course Target Mismatches", mismatched_target_items)

    sections.compact
  end

  def approval_parse_error_item(file, error)
    message = normalized_approval_error_message(error)
    type = error["type"].presence || error[:type].presence
    column = error["column"].presence || error[:column].presence
    location = column.present? ? "column #{column}" : nil
    issue = type.present? ? "#{type.to_s.humanize}: #{message}" : message
    prefix = [ file.file_name, location.presence ].compact.join(", ")

    "#{prefix}: #{issue}"
  end

  def normalized_approval_error_message(error)
    message = error["message"].presence || error[:message].presence || error.to_s
    column = error["column"].presence || error[:column].presence
    return message unless column.to_s.match?(/\bASSESSED LEVEL\b/i)

    message.gsub(/\bmastery points\b/i, "assessed level")
  end

  def approval_duplicate_upload_item(file, upload)
    batch_id = upload["batch_id"] || upload[:batch_id]
    uploaded_at = upload["created_at"] || upload[:created_at]
    prior = [ batch_id.present? ? "batch ##{batch_id}" : nil, uploaded_at.presence ].compact.join(", ")
    label = "#{file.file_name}: duplicate file upload"

    prior.present? ? "#{label} (#{prior})" : label
  end

  def approval_pending_student_items(pending_rows)
    pending_rows
      .group_by { |row| pending_student_group_key(row) }
      .values
      .map { |rows| approval_pending_student_group_item(rows) }
  end

  def pending_student_group_key(row)
    identity = row.student_uin.presence ||
               row.student_email.presence ||
               row.student_identifier.presence ||
               row.student_name.presence ||
               "pending-row-#{row.id}"

    [ row.student_identifier_type.presence || "student", identity.to_s.downcase.strip ]
  end

  def approval_pending_student_group_item(rows)
    primary_row = rows.first
    student = approval_pending_student_label(primary_row)
    course_codes = rows.map(&:course_code).compact_blank.uniq.sort
    competencies = rows.map(&:competency_title).compact_blank.uniq.sort
    competency_preview = competencies.first(3).join(", ")
    competency_label = if competencies.size > 3
      "#{competency_preview}, +#{competencies.size - 3} more"
    elsif competencies.size > 1
      "#{competencies.size} competencies: #{competency_preview}"
    else
      competency_preview
    end

    [
      student,
      "#{rows.size} pending #{rows.size == 1 ? 'row' : 'rows'}",
      course_codes.to_sentence,
      competency_label
    ].compact_blank.join(" | ")
  end

  def approval_pending_student_label(row)
    student_label = row.student_name.presence || row.student_identifier.presence || "Unmatched student"
    row.student_uin.present? ? "#{student_label} (UIN #{row.student_uin})" : student_label
  end

  def approval_pending_invalid_uin_item(row)
    file_name = row.grade_import_file&.file_name
    student_label = row.student_name.presence || row.student_identifier.presence || "Unmatched student"
    prefix = [ file_name, "column Student UIN" ].compact.join(", ")
    details = [ student_label, row.course_code, row.competency_title ].compact_blank.join(" | ")

    "#{prefix}: Invalid UIN: Student UIN must be exactly 9 digits; received #{row.student_uin}. #{details}"
  end

  def invalid_student_uin?(value)
    token = value.to_s.strip
    token.present? && !token.match?(/\A\d{9}\z/)
  end

  def approval_missing_target_item(row)
    [
      row[:course_code],
      row[:competency],
      row[:affected_label].presence || row[:student],
      "missing course target"
    ].compact_blank.join(" | ")
  end

  def approval_course_code_issue_item(row)
    [
      row[:course_code],
      row[:affected_label].presence || row[:student],
      row[:course_code_issue].presence || "course code must include department, course number, and section"
    ].compact_blank.join(" | ")
  end

  def approval_configured_target_mismatch_item(row)
    uploaded = row[:course_target].presence || "missing"
    configured = row[:configured_course_target].presence || "missing"

    [
      row[:course_code],
      row[:competency],
      row[:affected_label].presence || row[:student],
      "uploaded target #{uploaded}",
      "configured target #{configured}"
    ].compact_blank.join(" | ")
  end

  def target_met_label(assessed_level, course_target_level)
    GradeImports::TargetAttainmentReport.ui_label(assessed_level, course_target_level)
  end

  helper_method :target_met_label, :normalized_approval_error_message

  def target_met_export_label(assessed_level, course_target_level)
    GradeImports::TargetAttainmentReport.export_label(assessed_level, course_target_level)
  end

  def approval_section(title, items)
    return if items.blank?

    {
      title: title,
      count: items.size,
      collapsed: false,
      items: items
    }.compact
  end

  def student_match_options
    Student
      .includes(:user)
      .left_outer_joins(:user)
      .order(Arel.sql("LOWER(COALESCE(users.name, users.email, '')) ASC"), :student_id)
      .limit(1_000)
  end

  def rebuild_batch_ratings!
    GradeImports::BatchRatingRebuilder.call(batch: @batch)
    @batch.update!(
      evidence_count: @batch.grade_competency_evidences.count,
      rating_count: @batch.grade_competency_ratings.count,
      pending_count: @batch.grade_import_pending_rows.pending_student_match.count,
      summary: @batch.summary.merge(
        "ratings_rebuilt_at" => Time.current.iso8601,
        "ratings_rebuilt_by" => current_user.email
      )
    )
  end

  def reconcile_pending_row!(row, student)
    row.with_lock do
      evidence = @batch.grade_competency_evidences.find_or_initialize_by(source_key: row.source_key)
      attrs = {
        grade_import_file: row.grade_import_file,
        student_id: student.student_id,
        competency_title: row.competency_title,
        course_code: row.course_code,
        assignment_name: row.assignment_name,
        raw_grade: row.raw_grade,
        mapped_level: row.mapped_level,
        course_target_level: row.course_target_level,
        row_number: row.row_number,
        import_fingerprint: row.import_fingerprint,
        metadata: row.metadata.merge(
          "student_uin" => row.student_uin,
          "student_email" => row.student_email,
          "student_name" => row.student_name,
          "student_identifier" => row.student_identifier,
          "student_identifier_type" => row.student_identifier_type,
          "pending_row_id" => row.id,
          "manual_reconciled_at" => Time.current.iso8601,
          "manual_reconciled_by" => current_user.email
        )
      }
      attrs[:competency] = row.competency if GradeCompetencyEvidence.column_names.include?("competency_id")
      attrs[:course_offering] = row.course_offering if GradeCompetencyEvidence.column_names.include?("course_offering_id")

      evidence.assign_attributes(attrs)
      evidence.save!

      row.update!(
        status: "reconciled",
        matched_student_id: student.student_id,
        reconciled_at: Time.current
      )

      row.grade_import_file.update!(
        imported_rows: row.grade_import_file.grade_competency_evidences.count,
        pending_rows: row.grade_import_file.grade_import_pending_rows.pending_student_match.count
      )
    end
  end

  def sample_direct_competency_csv(kind)
    student = Student.includes(:user).order(:student_id).first
    student_name = student&.user&.name.presence || "Sample Student"
    student_id = student&.student_id || 1001
    student_uin = student&.uin.presence || "123456789"

    rows = case kind
    when "pending_match"
      [
        [ "Unmatched Canvas Student", nil, "999999999", 4, 3, 2, 3 ]
      ]
    when "duplicate"
      [
        [ student_name, student_id, student_uin, 4, 3, 3, 3 ],
        [ student_name, student_id, student_uin, 4, 3, 3, 3 ]
      ]
    when "bad_values"
      [
        [ student_name, student_id, student_uin, 4, " ", 3, "two" ],
        [ "Invalid UIN Student", nil, "12345", 4, 3, 3, 4 ]
      ]
    else
      [
        [ student_name, student_id, student_uin, 4, 3, 3, 4 ]
      ]
    end

    CSV.generate(headers: true) do |csv|
      csv << direct_competency_sample_headers
      rows.each { |row| csv << row }
    end
  end

  def direct_competency_sample_headers
    [
      "Student name",
      "Student ID",
      "Student UIN",
      "Policy Analysis COURSE TARGET",
      "Policy Analysis ASSESSED LEVEL",
      "Communication COURSE TARGET",
      "Communication ASSESSED LEVEL"
    ]
  end

  def sample_bad_mapping_workbook
    package = Axlsx::Package.new
    formatter = Exports::XlsxFormatter.new(package.workbook)

    package.workbook.add_worksheet(name: "PHPM_631_600") do |sheet|
      header_row = formatter.add_header_row(sheet, [ "Student", "ID", "SIS User ID", "SIS Login ID", "Section", "Final Project" ])
      formatter.add_data_row(sheet, [ "Points Possible", nil, nil, nil, nil, 100 ])
      formatter.add_data_row(sheet, [ "Sample Student", 1001, "123456789", "sample@example.edu", "PHPM-631-600", 94 ])
      formatter.finish_table(sheet, header_row: header_row, column_count: 6, widths: [ 22, 12, 16, 28, 18, 18 ])
    end

    package.workbook.add_worksheet(name: "mapping") do |sheet|
      header_row = formatter.add_header_row(sheet, [ "assignment_match_type", "assignment_match_value", "course_code", "competency_title", "score_basis", "min_score", "max_score", "competency_level", "active" ])
      formatter.add_data_row(sheet, [ "exact", "Final Project", "PHPM-631-600", "Bad Competency Name", "points", 90, 100, 5, true ])
      formatter.add_data_row(sheet, [ "exact", "Final Project", "PHPM-631-600", "Policy Analysis", "points", 80, 89.99, 4, true ])
      formatter.finish_table(sheet, header_row: header_row, column_count: 9, widths: [ 24, 24, 18, 32, 16, 12, 12, 18, 10 ])
    end

    package.to_stream.read
  end
end
