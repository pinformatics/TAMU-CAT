require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Production must use shared durable storage; local disk is ephemeral on Heroku
  # and is not shared with a separate import worker.
  active_storage_service = ENV.fetch("ACTIVE_STORAGE_SERVICE", "amazon").to_sym
  if active_storage_service == :local
    raise "ACTIVE_STORAGE_SERVICE=local is not supported in production; configure a durable service."
  end
  if active_storage_service == :amazon && ENV["DYNO"].present?
    raise "AWS_S3_BUCKET is required when ACTIVE_STORAGE_SERVICE=amazon." if ENV["AWS_S3_BUCKET"].blank?
    %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY].each do |name|
      raise "#{name} is required for Heroku S3 access." if ENV[name].blank?
    end
  end
  config.active_storage.service = active_storage_service

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Default Active Job adapter stays inline app-wide (most jobs have never
  # been verified running genuinely async in production). Individual job
  # classes can opt into Solid Queue via `self.queue_adapter = :solid_queue`
  # -- see GradeImports::BatchImportJob. Requires SOLID_QUEUE_IN_PUMA=true
  # (or a separate worker process) to actually dequeue jobs; see
  # config/puma.rb.
  config.active_job.queue_adapter = :inline

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  email_notifications_enabled = ActiveModel::Type::Boolean.new.cast(ENV.fetch("EMAIL_NOTIFICATIONS_ENABLED", "false"))
  app_host = ENV["APP_HOST"].presence ||
             ENV["HEROKU_APP_DEFAULT_DOMAIN_NAME"].presence ||
             (ENV["HEROKU_APP_NAME"].present? ? "#{ENV["HEROKU_APP_NAME"]}.herokuapp.com" : nil)

  if email_notifications_enabled && app_host.blank?
    raise "APP_HOST is required when EMAIL_NOTIFICATIONS_ENABLED=true so email links point to the correct app."
  end

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = {
    host: app_host || "localhost:3000",
    protocol: ENV.fetch("APP_PROTOCOL", "https")
  }

  # TAMU/SMTP email delivery. Emails are only sent when EMAIL_NOTIFICATIONS_ENABLED=true.
  # Configure these environment variables in production when enabling email:
  # EMAIL_NOTIFICATIONS_ENABLED, SMTP_ADDRESS, SMTP_PORT, SMTP_DOMAIN, SMTP_USER_NAME, SMTP_PASSWORD, MAILER_FROM.
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.smtp_settings = {
    address: ENV.fetch("SMTP_ADDRESS", "smtp-relay.tamu.edu"),
    port: ENV.fetch("SMTP_PORT", 587).to_i,
    domain: ENV.fetch("SMTP_DOMAIN", "tamu.edu"),
    user_name: ENV["SMTP_USER_NAME"],
    password: ENV["SMTP_PASSWORD"],
    authentication: ENV.fetch("SMTP_AUTHENTICATION", "plain").to_sym,
    enable_starttls_auto: ActiveModel::Type::Boolean.new.cast(ENV.fetch("SMTP_ENABLE_STARTTLS_AUTO", "true"))
  }.compact

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]
end
