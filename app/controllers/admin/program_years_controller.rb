# Manages the list of cohort/graduation year options (e.g., 2026, 2027) from the admin dashboard.
class Admin::ProgramYearsController < Admin::BaseController
  before_action :set_program_year, only: %i[update destroy]

  def create
    @program_year = ProgramYear.new(program_year_params)

    if @program_year.save
      redirect_back fallback_location: admin_program_setup_path(tab: "years"),
                    notice: "Cohort year (Class of #{@program_year.value}) created."
    else
      redirect_back fallback_location: admin_program_setup_path(tab: "years"),
                    alert: @program_year.errors.full_messages.to_sentence
    end
  end

  def update
    if @program_year.update(program_year_params)
      redirect_back fallback_location: admin_program_setup_path(tab: "years"),
                    notice: "Cohort year (Class of #{@program_year.value}) updated."
    else
      redirect_back fallback_location: admin_program_setup_path(tab: "years"),
                    alert: @program_year.errors.full_messages.to_sentence
    end
  end

  def destroy
    value = @program_year.value

    if @program_year.destroy
      redirect_back fallback_location: admin_program_setup_path(tab: "years"),
                    notice: "Cohort year (Class of #{value}) deleted."
    else
      redirect_back fallback_location: admin_program_setup_path(tab: "years"),
                    alert: @program_year.errors.full_messages.to_sentence
    end
  end

  def reorder
    ordered_ids = normalized_ordered_ids

    ProgramYear.transaction do
      ordered_ids.each_with_index do |id, index|
        ProgramYear.where(id: id).update_all(position: (index + 1) * 10, updated_at: Time.current)
      end
    end

    respond_to do |format|
      format.json { render json: { status: "ok" } }
      format.html do
        redirect_back fallback_location: admin_program_setup_path(tab: "years"),
                      notice: "Cohort order updated."
      end
    end
  end

  private

  def program_year_params
    params.require(:program_year).permit(:value, :position, :active)
  end

  def set_program_year
    @program_year = ProgramYear.find(params[:id])
  end

  def normalized_ordered_ids
    Array(params[:ordered_ids]).flat_map { |value| value.to_s.split(",") }.filter_map do |value|
      Integer(value, exception: false)
    end
  end
end
