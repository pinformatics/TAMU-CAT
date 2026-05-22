# frozen_string_literal: true

class NotificationMailer < ApplicationMailer
  def notification_email
    @notification = params.fetch(:notification)
    @user = @notification.user
    @target_path = @notification.target_path_for(@user)

    mail(to: @user.email, subject: @notification.title)
  end
end
