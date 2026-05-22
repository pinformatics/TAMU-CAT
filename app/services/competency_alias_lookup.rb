# frozen_string_literal: true

require "csv"

class CompetencyAliasLookup
  DEFAULT_PATH = Rails.root.join("db", "data", "competency_aliases.csv")
  REQUIRED_HEADERS = %w[raw_string canonical_competency_title].freeze

  class << self
    def resolve(value, path: DEFAULT_PATH, canonical_titles: Reports::DataAggregator::COMPETENCY_TITLES)
      new(path:, canonical_titles:).resolve(value)
    end

    def entries(path: DEFAULT_PATH, canonical_titles: Reports::DataAggregator::COMPETENCY_TITLES)
      new(path:, canonical_titles:).entries
    end

    def suggestions(value, path: DEFAULT_PATH, canonical_titles: Reports::DataAggregator::COMPETENCY_TITLES, limit: 3)
      new(path:, canonical_titles:).suggestions(value, limit:)
    end

    def normalize(value)
      value.to_s
           .downcase
           .gsub("&", " and ")
           .gsub(/\band\b/, " and ")
           .gsub(/[^\p{Alnum}]+/, " ")
           .squeeze(" ")
           .strip
    end
  end

  def initialize(path: DEFAULT_PATH, canonical_titles: Reports::DataAggregator::COMPETENCY_TITLES)
    @path = Pathname(path)
    @canonical_titles = Array(canonical_titles)
  end

  def resolve(value)
    token = self.class.normalize(value)
    return if token.blank?

    lookup[token]
  end

  def entries
    rows.map do |row|
      {
        raw_string: row.fetch("raw_string").to_s.strip,
        canonical_competency_title: row.fetch("canonical_competency_title").to_s.strip,
        source: row["source"].to_s.strip.presence,
        notes: row["notes"].to_s.strip.presence,
        active: active_row?(row)
      }
    end
  end

  def suggestions(value, limit: 3)
    token = self.class.normalize(value)
    return [] if token.blank?

    suggestion_candidates
      .map do |candidate|
        distance = edit_distance(token, candidate.fetch(:normalized))
        max_length = [ token.length, candidate.fetch(:normalized).length ].max
        score = max_length.zero? ? 1.0 : 1.0 - (distance.to_f / max_length)
        candidate.merge(distance:, score:)
      end
      .select { |candidate| candidate[:score] >= 0.72 || candidate[:distance] <= 4 }
      .sort_by { |candidate| [ -candidate[:score], candidate[:distance], candidate[:raw_string].length ] }
      .uniq { |candidate| candidate[:canonical_competency_title] }
      .first(limit)
  end

  private

  attr_reader :path, :canonical_titles

  def lookup
    @lookup ||= begin
      canonical_lookup = canonical_titles.index_by { |title| self.class.normalize(title) }
      csv_lookup = rows.each_with_object({}) do |row, memo|
        next unless active_row?(row)

        raw = row.fetch("raw_string").to_s.strip
        canonical = row.fetch("canonical_competency_title").to_s.strip
        next if raw.blank? || canonical.blank?

        canonical_title = canonical_titles.find { |title| self.class.normalize(title) == self.class.normalize(canonical) }
        next if canonical_title.blank?

        memo[self.class.normalize(raw)] = canonical_title
      end

      canonical_lookup.merge(csv_lookup)
    end
  end

  def suggestion_candidates
    @suggestion_candidates ||= begin
      canonical_candidates = canonical_titles.map do |title|
        {
          raw_string: title,
          canonical_competency_title: title,
          source: "canonical",
          normalized: self.class.normalize(title)
        }
      end

      alias_candidates = entries.select { |entry| entry[:active] }.filter_map do |entry|
        canonical = resolve(entry[:raw_string])
        next if canonical.blank?

        {
          raw_string: entry[:raw_string],
          canonical_competency_title: canonical,
          source: entry[:source].presence || "alias",
          normalized: self.class.normalize(entry[:raw_string])
        }
      end

      (canonical_candidates + alias_candidates).uniq { |candidate| [ candidate[:normalized], candidate[:canonical_competency_title] ] }
    end
  end

  def edit_distance(left, right)
    left_chars = left.chars
    right_chars = right.chars
    previous = (0..right_chars.length).to_a

    left_chars.each_with_index do |left_char, i|
      current = [ i + 1 ]
      right_chars.each_with_index do |right_char, j|
        cost = left_char == right_char ? 0 : 1
        current << [
          current[j] + 1,
          previous[j + 1] + 1,
          previous[j] + cost
        ].min
      end
      previous = current
    end

    previous.last
  end

  def rows
    @rows ||= begin
      return [] unless path.exist?

      parsed = CSV.read(path, headers: true, encoding: "bom|utf-8")
      missing = REQUIRED_HEADERS - parsed.headers.map(&:to_s)
      raise "Competency alias lookup is missing required column(s): #{missing.join(', ')}" if missing.any?

      parsed.map(&:to_h)
    end
  end

  def active_row?(row)
    token = row.fetch("active", "true").to_s.strip.downcase
    token.blank? || %w[true t yes y 1].include?(token)
  end
end
