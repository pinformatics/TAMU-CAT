require "test_helper"
require "tempfile"

class CompetencyAliasLookupTest < ActiveSupport::TestCase
  setup do
    @canonical_titles = [ "Policy Analysis", "Systems Thinking" ]
  end

  test "normalize expands symbols and trims punctuation" do
    assert_equal "policy and systems", CompetencyAliasLookup.normalize(" Policy & Systems!!! ")
  end

  test "missing alias file still resolves canonical titles and returns no entries" do
    missing_path = Rails.root.join("tmp", "missing-aliases-#{SecureRandom.hex(4)}.csv")
    lookup = CompetencyAliasLookup.new(path: missing_path, canonical_titles: @canonical_titles)

    assert_equal [], lookup.entries
    assert_equal "Policy Analysis", lookup.resolve("policy analysis")
    assert_nil lookup.resolve("")
  end

  test "entries resolve active aliases and ignore inactive or invalid canonical rows" do
    path = write_alias_csv(<<~CSV)
      raw_string,canonical_competency_title,active,source,notes
      Policy Alias,Policy Analysis,yes,faculty,common
      Inactive Alias,Systems Thinking,no,faculty,old
      Missing Canonical,Not Real,true,faculty,bad
      Blank Active,Systems Thinking,,faculty,blank means active
    CSV

    lookup = CompetencyAliasLookup.new(path: path, canonical_titles: @canonical_titles)
    entries = lookup.entries

    assert_equal 4, entries.size
    assert_equal "faculty", entries.first[:source]
    assert_equal "common", entries.first[:notes]
    assert_equal "Policy Analysis", lookup.resolve("policy alias")
    assert_equal "Systems Thinking", lookup.resolve("blank active")
    assert_nil lookup.resolve("inactive alias")
    assert_nil lookup.resolve("missing canonical")
  end

  test "suggestions include canonical and alias candidates with limits" do
    path = write_alias_csv(<<~CSV)
      raw_string,canonical_competency_title,active,source,notes
      System Think,Systems Thinking,true,faculty,
      Policy Alias,Policy Analysis,true,,
    CSV

    suggestions = CompetencyAliasLookup.suggestions(
      "system thinking",
      path: path,
      canonical_titles: @canonical_titles,
      limit: 1
    )

    assert_equal 1, suggestions.size
    assert_equal "Systems Thinking", suggestions.first[:canonical_competency_title]
    assert suggestions.first[:score] >= 0.72
    assert_equal [], CompetencyAliasLookup.suggestions(" ", path: path, canonical_titles: @canonical_titles)
  end

  test "bad alias files raise a clear missing header error" do
    path = write_alias_csv("raw_string\nPolicy Alias\n")

    error = assert_raises(RuntimeError) do
      CompetencyAliasLookup.entries(path: path, canonical_titles: @canonical_titles)
    end

    assert_match "missing required column", error.message
  end

  private

  def write_alias_csv(content)
    file = Tempfile.new([ "competency-aliases", ".csv" ])
    file.write(content)
    file.close
    file.path
  end
end
