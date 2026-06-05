class SettingsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_user

  # GET /settings
  def show
  end

  # GET /settings/edit
  def edit
  end

  # PATCH /settings
  def update
    if @user.update(settings_params)
      # Persisted successfully; updated_at will be updated automatically
      redirect_to settings_path, notice: "Settings updated successfully."
    else
      flash.now[:alert] = "Please correct the errors below."
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_user
    @user = current_user
  end

  def settings_params
    params.require(:user).permit(:language, :notifications_enabled, :in_app_notifications_enabled, :text_scale_percent)
  end
end
