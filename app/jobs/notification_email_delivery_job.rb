# frozen_string_literal: true

class NotificationEmailDeliveryJob < ApplicationJob
  queue_as :default

  def perform(notification_id:)
    notification = Notification.includes(:user).find(notification_id)
    user = notification.user
    return unless user&.notifications_enabled?
    return if user.email.blank?

    NotificationMailer.with(notification: notification).notification_email.deliver_now
    Rails.logger.info("[NotificationEmail] Sent notification #{notification.id} to user #{user.id}")
  rescue ActiveRecord::RecordNotFound => error
    Rails.logger.warn("[NotificationEmail] Skipped missing notification: #{error.message}")
  rescue StandardError => error
    Rails.logger.warn("[NotificationEmail] Failed notification #{notification_id}: #{error.class}: #{error.message}")
    raise
  end
end
