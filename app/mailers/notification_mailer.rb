# frozen_string_literal: true

class NotificationMailer < ApplicationMailer
  def notification_email
    @notification = params.fetch(:notification)
    @user = @notification.user
    @target_path = @notification.target_path_for(@user)
    @target_url = absolute_target_url(@target_path)

    mail(to: @user.email, subject: @notification.title)
  end

  private

  def absolute_target_url(path)
    return if path.blank?

    URI.join(root_url, path).to_s
  end
end
