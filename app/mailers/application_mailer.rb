# Base mailer class that sets default sender and layout.
class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAILER_FROM", "from@example.com")
  layout "mailer"
end
