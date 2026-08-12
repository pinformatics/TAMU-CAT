ENV["RAILS_ENV"] = "test"

require "shellwords"

# Start SimpleCov when coverage is requested by the test runner. The
# `run_tests.rb` script sets ENV['COVERAGE']='1' when the -c/--coverage
# flag is passed. Keep this block minimal to avoid loading SimpleCov in
# normal development runs.
if ENV["COVERAGE"] == "1"
  begin
    require "simplecov"
    # Use the Rails profile and enable branch coverage for more accuracy.
    SimpleCov.start "rails" do
      enable_coverage :branch
      minimum_coverage 95
      add_filter "/test/"
      add_group "Services", "app/services"
    end
    puts "📊 SimpleCov: coverage enabled"
  rescue LoadError
    warn "SimpleCov gem not available; install the 'simplecov' gem to generate coverage reports"
  end
end

app_root = File.expand_path("..", __dir__)
tailwind_build = File.join(app_root, "app/assets/builds/tailwind.css")

if ENV["SKIP_TAILWIND_BUILD"].to_s.empty? && !File.exist?(tailwind_build)
  system("cd #{Shellwords.escape(app_root)} && bin/rails tailwindcss:build", exception: true)
end

require_relative "../config/environment"
# Load seeds only when explicitly requested. Some test suites rely on fixtures or
# create their own data; running seeds by default can cause primary key
# collisions (sequences out of sync). Set ENV['LOAD_SEEDS']='true' to enable.
if Rails.env.test? && ENV["LOAD_SEEDS"] == "true"
  Rails.application.load_seed
end
require "rails/test_help"
require "minitest/mock"
require "factory_bot_rails"

# When using dockerized Postgres, the DB volume can persist between runs.
# Some tables are not covered by fixtures, so stale rows can cause FK
# validation failures during fixture load. Start each test run from a clean DB.
if Rails.env.test? && ENV["SKIP_TEST_DB_CLEAN"].to_s.empty?
  connection = ActiveRecord::Base.connection
  tables_to_truncate = connection.tables - %w[schema_migrations ar_internal_metadata]

  connection.disable_referential_integrity do
    tables_to_truncate.each do |table|
      quoted = connection.quote_table_name(table)
      connection.execute("TRUNCATE TABLE #{quoted} RESTART IDENTITY CASCADE")
    end
  end
end

# Load WebMock for HTTP stubbing in tests
require "webmock/minitest"
# Allow real HTTP connections to Google domains for evidence validation tests
WebMock.disable_net_connect!(
  allow_localhost: true,
  allow: [
    /drive\.google\.com/,
    /docs\.google\.com/,
    /googleusercontent\.com/
  ]
)

class ActiveSupport::TestCase
  include FactoryBot::Syntax::Methods
  parallelize(workers: 1)
  fixtures :admins,
           :advisor_feedback_submissions,
           :advisor_meeting_recaps,
           :advisors,
           :categories,
           :program_semesters,
           :questions,
           :feedbacks,
           :students,
           :surveys,
           :survey_track_assignments,
           :survey_assignments,
           :users,
           :survey_change_logs,
           :student_questions,
           :notifications
end

class ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper
end

class ActionController::TestCase
  include Devise::Test::ControllerHelpers
end
