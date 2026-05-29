class AccountsController < ApplicationController
  before_action :authenticate_user!

  # Shows the current user's account info
  def show
    @user = current_user
    render :edit
  end

  # Account information is read-only in this app; identity comes from sign-in data.
  def update
    redirect_to account_path, alert: "Account information is managed by your sign-in account and cannot be edited here."
  end
end
