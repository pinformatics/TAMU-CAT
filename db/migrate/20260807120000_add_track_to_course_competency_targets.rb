class AddTrackToCourseCompetencyTargets < ActiveRecord::Migration[8.0]
  def change
    add_column :course_competency_targets, :track, :string

    remove_index :course_competency_targets,
                  name: "index_course_competency_targets_unique_offering_competency"

    add_index :course_competency_targets,
              [ :course_offering_id, :competency_id, :track ],
              unique: true,
              name: "index_cct_unique_offering_competency_track"
  end
end
