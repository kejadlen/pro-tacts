require "roda"
require "sentry-ruby"

Sentry.init do |config|
  # TODO: Consolidate configuration
  config.dsn = ENV.fetch("SENTRY_DSN")

  # Get breadcrumbs from logs
  config.breadcrumbs_logger = [:sentry_logger, :http_logger]

  # Add data like request headers and IP for users, if applicable;
  # see https://docs.sentry.io/platforms/ruby/data-management/data-collected/ for more info
  config.send_default_pii = true

  # Trace all the things!
  config.traces_sample_rate = 1.0
end

class App < Roda
  plugin :not_found do
    Sentry.capture_message("404 Not Found", level: :warning, extra: {
      path: request.path,
      method: request.request_method
    })
    "Not Found"
  end

  route do |r|
    # GET / request
    r.root do
      r.redirect "/hello"
    end

    # /hello branch
    r.on "hello" do
      # Set variable for all routes in /hello branch
      @greeting = "Hello"

      # GET /hello/world request
      r.get "world" do
        "#{@greeting} world!"
      end

      # /hello request
      r.is do
        # GET /hello request
        r.get do
          "#{@greeting}!"
        end

        # POST /hello request
        r.post do
          puts "Someone said #{@greeting}!"
          r.redirect
        end
      end
    end
  end
end

run App.freeze.app
