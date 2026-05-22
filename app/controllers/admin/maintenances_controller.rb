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

  def normalize_target_levels
    result = TargetLevels::LegacyNormalizer.new.call

    AdminActivityLog.record!(
      admin: current_user,
      action: "other",
      description: "Normalized legacy competency target levels.",
      metadata: {
        created_count: result.created_count,
        removed_count: result.removed_count,
        skipped_count: result.skipped_count
      }
    )

    redirect_to admin_maintenance_path,
                notice: "Target levels normalized: #{result.created_count} created, #{result.removed_count} legacy rows removed, #{result.skipped_count} skipped."
  end
end
