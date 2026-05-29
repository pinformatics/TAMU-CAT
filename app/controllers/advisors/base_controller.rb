# Namespace for advisor-facing controllers and shared utilities.
module Advisors
  # Shared behavior for all controllers in the Advisors namespace, enforcing
  # advisor access and exposing helper predicates.
  class BaseController < ApplicationController
    before_action :require_advisor!

    helper_method :current_advisor_profile, :advisor_scope?

    private

    # Ensures only advisors or admins can reach advisor dashboards.
    #
    # @return [void]
    def require_advisor!
      return if current_user&.role_advisor? || current_user&.role_admin?

      redirect_to dashboard_path, alert: "Advisor access is required to open this page."
    end

    # @return [Boolean] whether the signed-in user is currently an advisor
    def advisor_scope?
      current_user&.role_advisor?
    end
  end
end
