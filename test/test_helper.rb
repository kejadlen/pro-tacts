
# A throwaway data directory holds the database the tests run against,
# seeded from test/fixtures/cards so the recorded macOS exchange resolves
# the same hrefs the real client did.
#
# The environment is set before the app is required rather than after it,
# so the requires cannot all sit at the top: the app reads configuration
# as it loads, because the unhandled-request middleware is given its
# directory at class-definition time. Set it afterwards and the captures
# land in log/ instead of tmp/.
require "pathname"

ENV["PRO_TACTS_DATA_DIR"] = (Pathname.new(__dir__).parent / "tmp" / "test-data").to_s

# Several tests provoke 404s. Keep the captures out of log/ and out of the
# fixtures; UnhandledRequestsTest points the middleware at its own tmpdir.
ENV["PRO_TACTS_UNHANDLED_DIR"] = (Pathname.new(__dir__).parent / "tmp" / "test-unhandled").to_s

require_relative "fixture_data"
require "pro_tacts/web"
require "minitest/autorun"

# Standing in for config.ru, which never runs here: build the store and
# hand it to the app.
ProTacts::Web.store = FixtureData.install(ENV.fetch("PRO_TACTS_DATA_DIR"))
