
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

require_relative "fixture_data"
require "pro_tacts/web"
require "minitest/autorun"

# Standing in for config.ru, which never runs here: build the store and
# hand it to the app.
ProTacts::Web.store = FixtureData.install(data_dir)
