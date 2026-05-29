# Base controller that restricts access to admin-only areas of the app.
#
# All controllers under the `Admin::` namespace inherit from this class to
# enforce authentication and provide helpers shared across the admin surface.
class Admin::BaseController < ApplicationController
  before_action :require_admin!

  helper ApplicationHelper

  helper_method :current_admin_profile

  private

  # Redirects non-admin users back to the dashboard with an error message.
  #
  # @return [void]
  def require_admin!
    return if current_user&.role_admin?

    # Avoid showing admin-only warnings to students if they hit an admin URL
    # accidentally (stale link, bookmark, etc.).
    if current_user&.role_student?
      redirect_to dashboard_path
    else
      redirect_to dashboard_path, alert: "Admin access is required to open this page."
    end
  end

  # @return [Admin, nil] the admin profile for the logged-in user, if present.
  def current_admin_profile
    current_user&.admin_profile
  end
end
