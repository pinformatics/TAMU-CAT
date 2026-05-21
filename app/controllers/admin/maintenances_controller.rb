class Admin::MaintenancesController < Admin::BaseController
  def show
    @maintenance_enabled = SiteSetting.maintenance_enabled?
    @data_model_health = DataModelHealthCheck.new.call
  end

  def update
    enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])
    SiteSetting.set_maintenance_enabled!(enabled)

    redirect_to admin_maintenance_path,
                notice: (enabled ? "Maintenance mode enabled." : "Maintenance mode disabled.")
  end
end
