class CreateAdvisorMeetingRecaps < ActiveRecord::Migration[8.1]
  def change
    create_table :advisor_meeting_recaps do |t|
      t.references :student, null: false, foreign_key: { to_table: :students, primary_key: :student_id, on_delete: :cascade }
      t.references :advisor, null: false, foreign_key: { to_table: :advisors, primary_key: :advisor_id, on_delete: :cascade }
      t.references :program_semester, null: false, foreign_key: { on_delete: :cascade }
      t.string :meeting_type, null: false
      t.text :academic_advising_notes
      t.text :career_advising_notes
      t.text :general_notes

      t.timestamps
    end

    add_index :advisor_meeting_recaps, [ :student_id, :program_semester_id, :meeting_type ],
      unique: true, name: "index_meeting_recaps_on_student_semester_type"
  end
end
