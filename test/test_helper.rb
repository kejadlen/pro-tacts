
# A throwaway data directory holds the database the tests run against,
# seeded from test/fixtures/cards so the recorded macOS exchange resolves
# the same hrefs the real client did. Every run builds its own tmpdirs,
# so nothing survives a run and two runs cannot collide.
#
# Cleanup runs through Minitest.after_run, not a plain at_exit: minitest
# 6's autorun nests one at_exit inside another and runs the tests inside
# the outer handler, so an at_exit registered after minitest/autorun —
# which the TestTask command and several test files require first —
# would fire BEFORE the tests and delete the database mid-suite.
#
# The removal is rm_rf rather than remove_entry because WebTest's
# wired-middleware tests rm_rf the configured unhandled directory to
# assert capture behavior from a clean slate; whether that directory
# still exists at cleanup depends on test order, and rm_rf tolerates
# it being gone.
#
# The environment is set before the app is required rather than after it,
# so the requires cannot all sit at the top: the app reads configuration
# as it loads, because the unhandled-request middleware is given its
# directory at class-definition time. Set it afterwards and the captures
# land in log/ instead of the tmpdir.
require "fileutils"
require "minitest"
require "pathname"
require "tmpdir"

data_dir = Pathname.new(Dir.mktmpdir("pro-tacts-test"))
ENV["PRO_TACTS_DATA_DIR"] = data_dir.to_s
Minitest.after_run { FileUtils.rm_rf(data_dir) }

# Several tests provoke 404s. Keep the captures out of log/ and out of the
# fixtures; UnhandledRequestsTest points the middleware at its own tmpdir.
unhandled_dir = Pathname.new(Dir.mktmpdir("pro-tacts-unhandled"))
ENV["PRO_TACTS_UNHANDLED_DIR"] = unhandled_dir.to_s
Minitest.after_run { FileUtils.rm_rf(unhandled_dir) }

# Debug exchanges, when PRO_TACTS_DEBUG is exported for a test run, get
# their own log, truncated per run: stderr would bury the test progress
# under full bodies, and log/debug.log is for real client sessions only.
ENV["PRO_TACTS_DEBUG_LOG"] ||= "log/test.log"
File.truncate("log/test.log", 0) if File.exist?("log/test.log")

require_relative "fixture_data"
require "pro_tacts/web"
require "sentry-ruby"
require "sentry/test_helper"

# Sentry is initialized here rather than left dormant because the gem's
# test helper builds on an initialized SDK. The DSN is forced nil rather
# than read from the environment, so a real SENTRY_DSN in this shell
# cannot point a test run at a live project. init also registers
# at_exit { close }, and the suite's runner requires minitest/autorun
# before any of this loads — so Sentry's close fires before minitest's
# at_exit runs the tests, and setup (SentryMessages#setup_sentry)
# re-opens the SDK when it finds it closed. Before minitest/autorun
# regardless, per the rule the header states, so direct single-file
# runs — where this file is the entry — keep the close after the tests.
Sentry.init { |sentry| sentry.dsn = nil }

require "minitest/autorun"

# Standing in for config.ru, which never runs here: build the store and
# hand it to the app.
ProTacts::Web.store = FixtureData.install(data_dir)

# The helper's other half: setup_sentry_test re-points the SDK at a
# dummy DSN and a recording transport, so what the app reports is
# observable in sentry_events without anything being sent and without
# redefining Sentry.capture_message. This suite's assertions read
# report texts, so the recorded Sentry::ErrorEvents also become the
# message strings, in capture order. Shared by the two test classes
# whose layers report — the web's PUT a broken parser assumption, the
# store its birthday model what it cannot recompose.
module SentryMessages
  def setup_sentry
    Sentry.init { |sentry| sentry.dsn = nil } unless Sentry.initialized?
    setup_sentry_test
  end

  def sentry_messages
    sentry_events.map { it.message }
  end
end
