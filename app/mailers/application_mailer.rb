# Base mailer class that sets default sender and layout.
class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAILER_FROM", "noreply@tamu.edu")
  layout "mailer"
end
