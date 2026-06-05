# Lists and manages in-app notifications for the signed-in user.
class NotificationsController < ApplicationController
  before_action :ensure_in_app_notifications_enabled!, except: :index
  before_action :set_notification, only: %i[show update]

  PER_PAGE = 20

  # Displays the user's notifications sorted by newest first.
  #
  # @return [void]
  def index
    mark_all_unread_notifications_read!
    load_notification_state

    @page = params.fetch(:page, 1).to_i
    @page = 1 if @page < 1

    unless in_app_notifications_enabled_for?(current_user)
      @notifications_disabled = true
      @notifications = Notification.none
      @total_notifications = 0
      @total_pages = 0
      return
    end

    notifications_scope = current_user.notifications.recent
    @notifications = notifications_scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    @total_notifications = notifications_scope.count
    @total_pages = (@total_notifications / PER_PAGE.to_f).ceil
  end

  # Shows a single notification and marks it read.
  #
  # @return [void]
  def show
    mark_notification_read(@notification)

    target = @notification.target_path_for(current_user)
    redirect_to(target.presence || notifications_path)
  end

  # Marks a notification as read.
  #
  # @return [void]
  def update
    mark_notification_read(@notification)
    respond_to do |format|
      format.turbo_stream
      format.html do
        redirect_back fallback_location: notifications_path, notice: "Notification marked as read."
      end
      format.json { head :no_content }
    end
  end

  # Marks every unread notification for the user as read in bulk.
  #
  # @return [void]
  def mark_all_read
    current_user.notifications.unread.update_all(read_at: Time.current)
    respond_to do |format|
      format.html do
        redirect_back fallback_location: notifications_path, notice: "All notifications marked as read."
      end
      format.json { head :no_content }
    end
  end

  private

  def ensure_in_app_notifications_enabled!
    return if in_app_notifications_enabled_for?(current_user)

    redirect_to settings_path, alert: "In-app notifications are turned off. Use Settings to turn them back on."
  end

  # @return [void]
  def set_notification
    @notification = current_user.notifications.find(params[:id])
  end

  # @param notification [Notification]
  # @return [void]
  def mark_notification_read(notification)
    notification.mark_read! unless notification.read?
  end

  def mark_all_unread_notifications_read!
    current_user.notifications.unread.update_all(read_at: Time.current)
  end
end
