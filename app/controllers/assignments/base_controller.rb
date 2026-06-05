# Namespace for shared assignment-management controllers.
module Assignments
  # Shared behavior for assignment tools (survey assignment, etc.).
  #
  # Accessible to advisors and admins.
  class BaseController < ApplicationController
    before_action :require_assignment_access!

    helper_method :current_advisor_profile

    private

    # Ensures only advisors or admins can reach assignment pages.
    def require_assignment_access!
      return if current_user&.role_advisor? || current_user&.role_admin?

      redirect_to dashboard_path, alert: STAFF_ONLY_MESSAGE
    end
  end
end
