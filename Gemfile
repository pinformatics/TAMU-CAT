ruby "3.4.6"


source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.0"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
gem "tailwindcss-rails"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
gem "aws-sdk-s3", require: false
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"
gem "csv"
gem "commonmarker"

# View components (extract reusable UI into Ruby components)
gem "view_component"

group :development do
  # Provide wkhtmltopdf binary for local PDF generation
  gem "wkhtmltopdf-binary"
end

# Server-rendered PDF generation via wkhtmltopdf/WickedPdf
gem "wicked_pdf"

# Excel export support
gem "caxlsx"
gem "roo"

# Streaming xlsx reader -- unlike Roo, doesn't load the whole workbook into
# memory at once. Used for the largest grade-import files (see
# GradeImports::BatchProcessor).
gem "creek"

# Bundles multiple generated PDFs into one download (see
# ReportsController#export_by_cohort). Already present transitively via
# caxlsx/active_storage; pinned here since we call it directly.
gem "rubyzip", require: "zip"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ mingw mswin x64_mingw jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

# Authentication gems
gem "devise"
gem "omniauth"
gem "omniauth-google-oauth2"
gem "omniauth-rails_csrf_protection"

group :development, :test do
  gem "factory_bot_rails"
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri mingw x64_mingw ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop", require: false
  gem "rubocop-rails-omakase", require: false

  # API documentation generator [https://yardoc.org]
  gem "yard", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Minitest 6 extracts minitest/mock to its own gem; keep both present for
  # tests that use Object#stub and Minitest::Mock.
  gem "minitest", "~> 6.0"
  gem "minitest-mock", "~> 5.27"

  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"

  # RSpec for behavior-driven tests (optional, installed if you want to run rspec)
  gem "rspec-rails"
  gem "rspec"

  # Code coverage analysis
  gem "simplecov", require: false
  gem "simplecov-html", require: false

  # HTTP stubbing for testing
  gem "webmock"

  # Controller testing helpers
  gem "rails-controller-testing"
end
