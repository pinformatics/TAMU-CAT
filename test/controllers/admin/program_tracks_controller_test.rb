require "test_helper"

class Admin::ProgramTracksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin)
    @student = users(:student)
  end

  test "non-admin is redirected" do
    sign_in @student

    post admin_program_tracks_path, params: {
      program_track: {
        key: "",
        name: "Residential",
        position: 10,
        active: true
      }
    }

    assert_redirected_to dashboard_path
  end

  test "admin can create program track and auto-generates key" do
    sign_in @admin

    assert_difference "ProgramTrack.count", 1 do
      post admin_program_tracks_path, params: {
        program_track: {
          key: "",
          name: "My New Track",
          position: 30,
          active: true
        }
      }
    end

    record = ProgramTrack.order(:id).last
    assert_equal "my-new-track", record.key
    assert_equal "My New Track", record.name

    assert_redirected_to admin_program_setup_path(tab: "tracks")
    assert_match(/created/i, flash[:notice].to_s)
  end

  test "admin create shows errors when invalid" do
    sign_in @admin

    assert_difference "ProgramTrack.count", 0 do
      post admin_program_tracks_path, params: { program_track: { key: "", name: "" } }
    end

    assert_redirected_to admin_program_setup_path(tab: "tracks")
    assert flash[:alert].present?
  end

  test "admin can update program track and auto-generates key" do
    sign_in @admin

    program_track = ProgramTrack.create!(key: "custom", name: "Custom", position: 10, active: true)

    patch admin_program_track_path(program_track), params: {
      program_track: {
        key: "",
        name: "Updated Name",
        position: 40
      }
    }

    assert_redirected_to admin_program_setup_path(tab: "tracks")

    program_track.reload
    assert_equal "updated-name", program_track.key
    assert_equal "Updated Name", program_track.name
  end

  test "admin update shows errors when invalid" do
    sign_in @admin

    program_track = ProgramTrack.create!(key: "custom2", name: "Custom2", position: 10, active: true)

    patch admin_program_track_path(program_track), params: { program_track: { key: "", name: "" } }

    assert_redirected_to admin_program_setup_path(tab: "tracks")
    assert flash[:alert].present?
  end

  test "admin can delete program track" do
    sign_in @admin

    program_track = ProgramTrack.create!(key: "delete-me", name: "Delete Me", position: 10, active: true)

    assert_difference "ProgramTrack.count", -1 do
      delete admin_program_track_path(program_track)
    end

    assert_redirected_to admin_program_setup_path(tab: "tracks")
    assert_match(/deleted/i, flash[:notice].to_s)
  end

  test "admin can reorder program tracks" do
    sign_in @admin

    first = ProgramTrack.create!(key: "first-track", name: "First Track", position: 10, active: true)
    second = ProgramTrack.create!(key: "second-track", name: "Second Track", position: 20, active: true)
    third = ProgramTrack.create!(key: "third-track", name: "Third Track", position: 30, active: true)

    patch reorder_admin_program_tracks_path,
          params: { ordered_ids: [ third.id, first.id, second.id ] },
          as: :json

    assert_response :success
    assert_equal [ third.id, first.id, second.id ], ProgramTrack.where(id: [ first.id, second.id, third.id ]).ordered.pluck(:id)
    assert_equal 10, third.reload.position
    assert_equal 20, first.reload.position
    assert_equal 30, second.reload.position
  end

  test "non-admin cannot reorder program tracks" do
    sign_in @student

    patch reorder_admin_program_tracks_path, params: { ordered_ids: [] }, as: :json

    assert_redirected_to dashboard_path
  end
end
