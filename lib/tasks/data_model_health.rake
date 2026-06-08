namespace :data_model do
  desc "Print a data-model health report for student lifecycle, advisor history, competencies, and courses"
  task health: :environment do
    report = DataModelHealthCheck.new.call

    puts "Data model health generated at #{report[:generated_at]}"
    puts "Issues: #{report[:issue_count]} (critical: #{report[:critical_count]}, warnings: #{report[:warning_count]})"
    puts

    report[:sections].each do |section|
      puts section.label
      section.checks.each do |check|
        status = check.ok? ? "OK" : check.severity.to_s.upcase
        if check.ok? && check.key.to_s.start_with?("missing_")
          puts "  [#{status}] #{check.label.delete_prefix('Missing ')} present"
        else
          puts "  [#{status}] #{check.label}: #{check.count}"
        end
      end
      puts
    end
  end
end
