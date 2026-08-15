# frozen_string_literal: true

# Marks the process as running tests before anything requires the app, so
# web.rb skips Sentry.init and no SENTRY_DSN is needed.
ENV["RACK_ENV"] = "test"

require "minitest/autorun"
