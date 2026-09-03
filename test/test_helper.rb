
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
require "minitest/autorun"

# Standing in for config.ru, which never runs here: build the store and
# hand it to the app.
ProTacts::Web.store = FixtureData.install(data_dir)

# Sentry's capture_message, made observable for the length of a block and
# restored after, so what one test captures cannot leak into the next.
# Sentry is never initialized under test, so the original is inert
# anyway — this only makes it observable. Returns what was captured.
#
# Here rather than in one test class because the reports are raised from
# two layers: the web's PUT reports a broken parser assumption, the store
# reports what its birthday model could not recompose.
module CapturingSentry
  def capturing_sentry
    messages = []
    original = Sentry.method(:capture_message)
    Sentry.define_singleton_method(:capture_message) { |message, **| messages << message }
    begin
      yield messages
    ensure
      Sentry.define_singleton_method(:capture_message, original)
    end
    messages
  end
end
