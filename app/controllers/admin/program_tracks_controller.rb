# Manages the catalog of program tracks from the admin dashboard.
class Admin::ProgramTracksController < Admin::BaseController
  before_action :set_program_track, only: %i[update destroy]

  def create
    @program_track = ProgramTrack.new(program_track_params)

    if @program_track.key.to_s.strip.blank? && @program_track.name.to_s.strip.present?
      @program_track.key = @program_track.name.to_s.parameterize
    end

    if @program_track.save
      redirect_back fallback_location: admin_program_setup_path(tab: "tracks"),
                    notice: "Track '#{@program_track.name}' created."
    else
      redirect_back fallback_location: admin_program_setup_path(tab: "tracks"),
                    alert: @program_track.errors.full_messages.to_sentence
    end
  end

  def update
    @program_track.assign_attributes(program_track_params)

    if @program_track.key.to_s.strip.blank? && @program_track.name.to_s.strip.present?
      @program_track.key = @program_track.name.to_s.parameterize
    end

    if @program_track.save
      redirect_back fallback_location: admin_program_setup_path(tab: "tracks"),
                    notice: "Track '#{@program_track.name}' updated."
    else
      redirect_back fallback_location: admin_program_setup_path(tab: "tracks"),
                    alert: @program_track.errors.full_messages.to_sentence
    end
  end

  def destroy
    name = @program_track.name

    if @program_track.destroy
      redirect_back fallback_location: admin_program_setup_path(tab: "tracks"),
                    notice: "Track '#{name}' deleted."
    else
      redirect_back fallback_location: admin_program_setup_path(tab: "tracks"),
                    alert: @program_track.errors.full_messages.to_sentence
    end
  end

  def reorder
    ordered_ids = normalized_ordered_ids

    ProgramTrack.transaction do
      ordered_ids.each_with_index do |id, index|
        ProgramTrack.where(id: id).update_all(position: (index + 1) * 10, updated_at: Time.current)
      end
    end

    respond_to do |format|
      format.json { render json: { status: "ok" } }
      format.html do
        redirect_back fallback_location: admin_program_setup_path(tab: "tracks"),
                      notice: "Track order updated."
      end
    end
  end

  private

  def program_track_params
    params.require(:program_track).permit(:key, :name, :position, :active)
  end

  def set_program_track
    @program_track = ProgramTrack.find(params[:id])
  end

  def normalized_ordered_ids
    Array(params[:ordered_ids]).flat_map { |value| value.to_s.split(",") }.filter_map do |value|
      Integer(value, exception: false)
    end
  end
end
