require "csv"
require "axlsx"

class Admin::GradeImportBatchesController < Admin::BaseController
  IMPORT_EXTENSIONS = GradeImports::FileUploadRouter::SUPPORTED_EXTENSIONS
  SAMPLE_IMPORT_KINDS = %w[success duplicate pending_match bad_mapping].freeze

  before_action :set_batch, only: %i[
    show approve commit reupload rollback recommit rebuild_ratings finalize semester destroy
    export_ratings error_report correction_file update_pending_row update_evidence
  ]

  def index
    @batches = GradeImportBatch.includes(:uploaded_by, :grade_import_files).order(created_at: :desc).limit(100)
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

    @batch = GradeImportBatch.create!(
      uploaded_by: current_user,
      program_semester_id: grade_import_batch_params[:program_semester_id].presence,
      summary: {
        "dry_run" => dry_run_requested?,
        "import_notes" => grade_import_batch_params[:import_notes].to_s.strip.presence
      }.compact
    )

    GradeImports::BatchProcessor.new(batch: @batch, files: files, dry_run: dry_run_requested?).call

    notice = dry_run_requested? ? "Preview completed. Review the results before committing." : "Grade import batch processed."
    redirect_to admin_grade_import_batch_path(@batch), notice: notice
  rescue StandardError => e
    Rails.logger.error("[Admin::GradeImportBatchesController#create] #{e.class}: #{e.message}")
    if @batch&.persisted?
      @batch.update(status: "failed", completed_at: Time.current, summary: { error: e.message })
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
    @match_rate = match_rate_for(@files)
    @failed_row_count = @files.sum(&:error_rows)
    @processed_row_count = @files.sum(&:imported_rows)
    @pending_row_count = @batch.grade_import_pending_rows.pending_student_match.count
    @duplicate_warnings = @files.sum { |file| file.parsed_content.dig("grade_sheet_debug", "duplicate_warning_count").to_i }
    @duplicate_upload_warnings = @files.sum { |file| file.parsed_content["duplicate_file_upload_count"].to_i }
    @validation_summary = validation_summary_for(@files)
    @target_warning_summary = target_warning_summary
    @student_match_options = student_match_options
  end

  def approve
    unless @batch.dry_run?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Only previews can be approved for commit." and return
    end

    unless @batch.needs_admin_approval? || target_warning_summary[:requires_review]
      redirect_to admin_grade_import_batch_path(@batch), alert: "Only previews with failed, pending, or target-warning rows need admin approval." and return
    end

    approved_summary = @batch.summary.merge(
      "admin_approved_at" => Time.current.iso8601,
      "admin_approved_by" => current_user.email
    )

    @batch.update!(summary: approved_summary)

    redirect_to admin_grade_import_batch_path(@batch),
                notice: "Preview approved. It can now be committed."
  end

  def commit
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

    redirect_to admin_grade_import_batch_path(@batch), notice: "Preview committed. This batch now appears in reportable course competency views."
  end

  def reupload
    if @batch.finalized?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch is finalized and locked. Files cannot be re-uploaded." and return
    end

    unless @batch.dry_run?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Only preview batches can be re-uploaded before commit." and return
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

    redirect_to admin_grade_import_batch_path(@batch), notice: "Corrected file re-uploaded. Matching filenames replaced previous rows in this batch."
  rescue StandardError => e
    Rails.logger.error("[Admin::GradeImportBatchesController#reupload] #{e.class}: #{e.message}")
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

    redirect_to admin_grade_import_batch_path(@batch), notice: "Batch rolled back. It is now hidden from downstream views but can be recommitted later."
  end

  def recommit
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

    redirect_to admin_grade_import_batch_path(@batch), notice: "Batch recommitted. Its course competency data is visible in the app again."
  end

  def rebuild_ratings
    if @batch.finalized?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch is finalized and locked. Ratings cannot be rebuilt." and return
    end

    rebuild_batch_ratings!

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

    redirect_to admin_grade_import_batch_path(@batch), notice: "Batch finalized and locked after review."
  end

  def semester
    if @batch.finalized?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch is finalized and locked. Semester cannot be changed." and return
    end

    @batch.update!(program_semester_id: grade_import_batch_params[:program_semester_id].presence)

    message = if @batch.program_semester.present?
      "Batch semester updated to #{@batch.program_semester.name}."
    else
      "Batch semester cleared. It will only appear in unfiltered course competency views."
    end

    redirect_to admin_grade_import_batch_path(@batch), notice: message
  end

  def destroy
    if @batch.finalized?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch is finalized and locked. It cannot be deleted." and return
    end

    batch_id = @batch.id
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
      redirect_to admin_grade_import_batch_path(@batch), notice: "Pending row matched to #{student.user&.display_name || student.student_id} and ratings rebuilt."
    else
      redirect_to admin_grade_import_batch_path(@batch), notice: "Pending row correction saved."
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    redirect_to admin_grade_import_batch_path(@batch), alert: "Could not update pending row: #{e.message}"
  end

  def update_evidence
    if @batch.finalized?
      redirect_to admin_grade_import_batch_path(@batch), alert: "This batch is finalized and locked. Evidence rows cannot be changed." and return
    end

    evidence = @batch.grade_competency_evidences.find(params[:evidence_id])
    evidence.update!(evidence_params)
    rebuild_batch_ratings!

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
        provenance_details: provenance_rows.map do |row|
          [
            row.course_code,
            row.assignment_name,
            "raw=#{row.raw_grade}",
            "level=#{row.mapped_level}",
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
          :provenance_details
        )
      end
    end
  end

  def error_report_csv
    CSV.generate(headers: true) do |csv|
      csv << %w[file_name status type row message]
      @batch.grade_import_files.find_each do |file|
        Array(file.parse_errors).each do |error|
          csv << [ file.file_name, file.status, error["type"].presence || "error", error["row"], error["message"] || error.to_s ]
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
        "Message",
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
            error["message"] || error.to_s,
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
          "Student could not be matched automatically. Add or correct UIN/email/name, then reconcile or re-upload.",
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
    else
      [
        [ student_name, student_id, student_uin, 4, 3, 3, 4 ],
        [ "Unmatched Canvas Student", nil, "999999999", 2, 3, 1, 4 ]
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
      "Student SIS ID",
      "EMHA Competencies > Health Care Environment and Community > Policy Analysis result",
      "EMHA Competencies > Health Care Environment and Community > Policy Analysis mastery points",
      "EMHA Competencies > Management Skills > Communication result",
      "EMHA Competencies > Management Skills > Communication mastery points"
    ]
  end

  def sample_bad_mapping_workbook
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "PHPM_631_600") do |sheet|
      sheet.add_row [ "Student", "ID", "SIS User ID", "SIS Login ID", "Section", "Final Project" ]
      sheet.add_row [ "Points Possible", nil, nil, nil, nil, 100 ]
      sheet.add_row [ "Sample Student", 1001, "123456789", "sample@example.edu", "PHPM-631-600", 94 ]
    end

    package.workbook.add_worksheet(name: "mapping") do |sheet|
      sheet.add_row [ "assignment_match_type", "assignment_match_value", "course_code", "competency_title", "score_basis", "min_score", "max_score", "competency_level", "active" ]
      sheet.add_row [ "exact", "Final Project", "PHPM-631-600", "Bad Competency Name", "points", 90, 100, 5, true ]
      sheet.add_row [ "exact", "Final Project", "PHPM-631-600", "Policy Analysis", "points", 80, 89.99, 4, true ]
    end

    package.to_stream.read
  end
end
