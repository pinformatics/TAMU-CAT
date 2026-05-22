# frozen_string_literal: true

require "yaml"

module TargetLevels
  class DefaultApplier
    Result = Struct.new(:created_count, :skipped_count, keyword_init: true)

    def initialize(program_semester_id:, track:, class_of:, defaults_path: Rails.root.join("db", "data", "default_target_levels.yml"))
      @program_semester_id = program_semester_id
      @track = track.to_s
      @class_of = class_of.to_i
      @defaults_path = defaults_path
    end

    def call
      levels = default_levels_for_track
      raise ArgumentError, "No default target levels found for #{track}." if levels.blank?

      competency_titles = Reports::DataAggregator::COMPETENCY_TITLES
      unless levels.size == competency_titles.size
        raise ArgumentError, "Default target levels for #{track} must include #{competency_titles.size} values."
      end

      created_count = 0
      skipped_count = 0

      ActiveRecord::Base.transaction do
        competency_titles.each_with_index do |title, index|
          existing = CompetencyTargetLevel.find_by(
            program_semester_id: program_semester_id,
            track: track,
            class_of: class_of,
            program_year: nil,
            competency_title: title
          )

          if existing.present?
            skipped_count += 1
            next
          end

          CompetencyTargetLevel.create!(
            program_semester_id: program_semester_id,
            track: track,
            class_of: class_of,
            program_year: nil,
            competency_title: title,
            target_level: levels[index]
          )
          created_count += 1
        end
      end

      Result.new(created_count: created_count, skipped_count: skipped_count)
    end

    private

    attr_reader :program_semester_id, :track, :class_of, :defaults_path

    def default_levels_for_track
      defaults = YAML.safe_load_file(defaults_path)
      track_config = defaults.fetch("tracks", {})[track]
      Array(track_config.is_a?(Hash) ? track_config["levels"] : nil).map(&:to_i)
    end
  end
end
