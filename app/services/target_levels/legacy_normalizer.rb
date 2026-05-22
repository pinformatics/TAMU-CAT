# frozen_string_literal: true

module TargetLevels
  class LegacyNormalizer
    LEGACY_PROGRAM_YEAR_TO_CLASS_OF = {
      1 => 2027,
      2 => 2026
    }.freeze

    Result = Struct.new(:created_count, :removed_count, :skipped_count, keyword_init: true)

    def call
      created_count = 0
      removed_count = 0
      skipped_count = 0

      ActiveRecord::Base.transaction do
        legacy_rows.each do |row|
          class_of = normalized_class_of(row)
          unless class_of
            skipped_count += 1
            next
          end

          canonical = CompetencyTargetLevel.find_or_initialize_by(
            program_semester_id: row.program_semester_id,
            track: row.track,
            class_of: class_of,
            program_year: nil,
            competency_title: row.competency_title
          )

          if canonical.new_record?
            canonical.target_level = row.target_level
            canonical.competency_id = row.competency_id if canonical.respond_to?(:competency_id=)
            canonical.save!
            created_count += 1
          end

          row.destroy!
          removed_count += 1
        end
      end

      Result.new(created_count: created_count, removed_count: removed_count, skipped_count: skipped_count)
    end

    private

    def legacy_rows
      CompetencyTargetLevel
        .where.not(program_year: nil)
        .or(CompetencyTargetLevel.where(class_of: LEGACY_PROGRAM_YEAR_TO_CLASS_OF.keys))
        .order(:program_semester_id, :track, :competency_title, :id)
    end

    def normalized_class_of(row)
      if row.class_of.in?(LEGACY_PROGRAM_YEAR_TO_CLASS_OF.keys)
        return LEGACY_PROGRAM_YEAR_TO_CLASS_OF[row.class_of]
      end

      return row.program_year if row.program_year.to_i >= 2026

      LEGACY_PROGRAM_YEAR_TO_CLASS_OF[row.program_year]
    end
  end
end
