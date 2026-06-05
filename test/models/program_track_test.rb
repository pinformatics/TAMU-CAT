require "test_helper"

class ProgramTrackTest < ActiveSupport::TestCase
  test "canonical key accepts program aliases keys and display names" do
    assert_equal "residential", ProgramTrack.canonical_key("rmha")
    assert_equal "executive", ProgramTrack.canonical_key("EMHA")
    assert_equal "residential", ProgramTrack.canonical_key(" residential ")
    assert_equal "executive", ProgramTrack.canonical_key("Executive")
    assert_nil ProgramTrack.canonical_key("unknown")
    assert_nil ProgramTrack.canonical_key(" ")
  end

  test "tracks hash falls back to defaults when data source is unavailable" do
    ProgramTrack.stub(:data_source_ready?, false) do
      assert_equal(
        { "residential" => "Residential", "executive" => "Executive" },
        ProgramTrack.tracks_hash
      )
      assert_nil ProgramTrack.seed_defaults!
    end
  end

  test "name and key helpers use canonicalized values" do
    assert_equal "Residential", ProgramTrack.name_for_key("RMHA")
    assert_includes ProgramTrack.names, "Executive"
    assert_includes ProgramTrack.keys, "residential"
  end
end
