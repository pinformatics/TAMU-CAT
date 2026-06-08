namespace :v6 do
  desc "Check whether the folded V6 course schema is present before QA or imports"
  task readiness: :environment do
    missing_sources = CourseCompetencyTarget::REQUIRED_DATA_SOURCES.reject do |source|
      ActiveRecord::Base.connection.data_source_exists?(source)
    end

    puts "V6 course schema readiness"
    CourseCompetencyTarget::REQUIRED_DATA_SOURCES.each do |source|
      status = missing_sources.include?(source) ? "MISSING" : "OK"
      puts "  [#{status}] #{source}"
    end

    if missing_sources.any?
      abort "Missing V6 course schema tables/views: #{missing_sources.join(', ')}"
    end
  end
end
