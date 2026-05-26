require "test_helper"

class ApplicationMailerTest < ActiveSupport::TestCase
  test "default sender configured" do
    assert_equal "noreply@tamu.edu", ApplicationMailer.default_params[:from]
  end

  test "mailer uses application layout" do
    layout = ApplicationMailer.respond_to?(:_layout) ? ApplicationMailer._layout : ApplicationMailer.default_params[:template_path]
    assert_equal "mailer", layout
  end
end
