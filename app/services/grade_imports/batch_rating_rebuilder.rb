module GradeImports
  class BatchRatingRebuilder
    def self.call(batch:)
      new(batch: batch).call
    end

    def initialize(batch:)
      @batch = batch
    end

    def call
      batch.grade_competency_ratings.delete_all

      evidence_has_competency_id = GradeCompetencyEvidence.column_names.include?("competency_id")
      rating_has_competency_id = GradeCompetencyRating.column_names.include?("competency_id")

      rows = if evidence_has_competency_id
        batch.grade_competency_evidences
             .group(:student_id, :competency_title)
             .pluck(
               :student_id,
               :competency_title,
               Arel.sql("MAX(competency_id)"),
               Arel.sql("MAX(mapped_level)"),
               Arel.sql("COUNT(*)")
             )
      else
        batch.grade_competency_evidences
             .group(:student_id, :competency_title)
             .pluck(
               :student_id,
               :competency_title,
               Arel.sql("MAX(mapped_level)"),
               Arel.sql("COUNT(*)")
             )
             .map { |student_id, competency_title, max_level, count| [ student_id, competency_title, nil, max_level, count ] }
      end

      return if rows.empty?

      timestamp = Time.current
      payload = rows.map do |student_id, competency_title, competency_id, max_level, count|
        row = {
          grade_import_batch_id: batch.id,
          student_id: student_id,
          competency_title: competency_title,
          aggregated_level: max_level,
          aggregation_rule: "max",
          evidence_count: count,
          created_at: timestamp,
          updated_at: timestamp
        }
        row[:competency_id] = competency_id if rating_has_competency_id
        row
      end

      GradeCompetencyRating.insert_all(payload)
    end

    private

    attr_reader :batch
  end
end
