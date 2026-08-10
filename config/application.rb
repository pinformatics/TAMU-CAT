require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module TamuCat
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # ViewComponent components live here.
    config.autoload_paths << Rails.root.join("app/components")
    config.eager_load_paths << Rails.root.join("app/components")

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    config.time_zone = ENV.fetch("APP_TIME_ZONE", "Central Time (US & Canada)")
    # config.eager_load_paths << Rails.root.join("extras")

    # Routes Solid Queue's own models (SolidQueue::Job, etc.) to the queue
    # database in every environment. This is separate from
    # config.active_job.queue_adapter (which stays :inline app-wide) -- it
    # only matters for job classes that explicitly opt into
    # `self.queue_adapter = :solid_queue`.
    config.solid_queue.connects_to = { database: { writing: :queue } }
  end
end
