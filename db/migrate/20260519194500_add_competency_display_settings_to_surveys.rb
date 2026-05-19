class AddCompetencyDisplaySettingsToSurveys < ActiveRecord::Migration[8.0]
  def change
    add_column :surveys, :show_course_competencies_with_survey, :boolean, null: false, default: false
    add_column :surveys, :advisor_numeric_feedback_enabled, :boolean, null: false, default: false
  end
end
