require "csv"

class Admin::GradeImportBatchesController < Admin::BaseController
  IMPORT_EXTENSIONS = GradeImports::FileUploadRouter::SUPPORTED_EXTENSIONS

  before_action :set_batch, only: %i[show approve commit rollback recommit semester destroy export_ratings error_report correction_file]

  def index
    @batches = GradeImportBatch.includes(:uploaded_by, :grade_import_files).order(created_at: :desc).limit(100)
  end

  def new
  end

  def create
    files = Array(params[:files]).compact_blank + Array(params[:folder_files]).compact_blank
    files = files.select { |file| IMPORT_EXTENSIONS.include?(File.extname(file.original_filename.to_s).downcase) }

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

    notice = dry_run_requested? ? "Preview completed. Review the results and re-upload to commit." : "Grade import batch processed."
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
    @pending_row_count = @files.sum(&:pending_rows)
    @duplicate_warnings = @files.sum { |file| file.parsed_content.dig("grade_sheet_debug", "duplicate_warning_count").to_i }
    @duplicate_upload_warnings = @files.sum { |file| file.parsed_content["duplicate_file_upload_count"].to_i }
    @validation_summary = validation_summary_for(@files)
  end

  def approve
    unless @batch.needs_admin_approval?
      redirect_to admin_grade_import_batch_path(@batch), alert: "Only previews with failed or pending rows need admin approval." and return
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
    if @batch.needs_admin_approval? && !@batch.admin_approved?
      redirect_to admin_grade_import_batch_path(@batch),
                  alert: "Review and approve this preview before committing because it has failed or pending rows." and return
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

  def rollback
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

  def semester
    @batch.update!(program_semester_id: grade_import_batch_params[:program_semester_id].presence)

    message = if @batch.program_semester.present?
      "Batch semester updated to #{@batch.program_semester.name}."
    else
      "Batch semester cleared. It will only appear in unfiltered course competency views."
    end

    redirect_to admin_grade_import_batch_path(@batch), notice: message
  end

  def destroy
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
      csv << %w[file_name status row message]
      @batch.grade_import_files.find_each do |file|
        Array(file.parse_errors).each do |error|
          csv << [ file.file_name, file.status, error["row"], error["message"] || error.to_s ]
        end
      end
    end
  end

  def correction_file_csv
    CSV.generate(headers: true) do |csv|
      csv << [
        "Row Type",
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
end
