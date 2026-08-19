
# Marks the process as running tests before anything requires the app, so
# web.rb skips Sentry.init and no SENTRY_DSN is needed. The fixtures
# directory serves as the data directory: its contacts/ holds the card the
# recorded macOS exchange asked for, so the replay resolves the same hrefs
# the client did.
ENV["RACK_ENV"] = "test"

require "pathname"

ENV["PRO_TACTS_DATA_DIR"] = (Pathname.new(__dir__) / "fixtures").to_s

require "minitest/autorun"
