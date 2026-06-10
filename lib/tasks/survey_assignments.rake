namespace :survey_assignments do
  desc "Backfill missing survey assignment completion timestamps from completed answer sets"
  task backfill_completed: :environment do
    backfill = SurveyAssignments::CompletionBackfill.new(scope: SurveyAssignment.where(completed_at: nil))
    count = backfill.call
    puts "Backfilled #{count} completed survey assignment#{'s' unless count == 1}."
    puts "Checked #{backfill.stats[:checked]} assignments without completed_at."
    puts "  From submitted/revised response versions: #{backfill.stats[:from_versions]}"
    puts "  From complete current answer sets: #{backfill.stats[:from_answer_sets]}"
    puts "  Still incomplete or missing data: #{backfill.stats[:skipped]}"
  end
end
