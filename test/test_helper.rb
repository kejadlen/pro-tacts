
# Marks the process as running tests before anything requires the app, so
# web.rb skips Sentry.init and no SENTRY_DSN is needed. The contacts
# directory holds the card the recorded macOS exchange asked for, so the
# fixture replay resolves the same hrefs the client did.
ENV["RACK_ENV"] = "test"
ENV["PRO_TACTS_CONTACTS_DIR"] = File.expand_path("fixtures/contacts", __dir__)

require "minitest/autorun"
