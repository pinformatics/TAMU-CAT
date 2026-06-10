namespace :survey_assignments do
  desc "Backfill missing survey assignment completion timestamps from completed answer sets"
  task backfill_completed: :environment do
    count = SurveyAssignments::CompletionBackfill.call
    puts "Backfilled #{count} completed survey assignment#{'s' unless count == 1}."
  end
end
