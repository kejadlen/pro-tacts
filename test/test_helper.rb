
# Drops an ambient SENTRY_DSN (e.g. exported by direnv) before anything
# requires the app, so Sentry stays uninitialized here and the 404 tests
# cannot ship events. The fixtures directory serves as the data directory:
# its contacts/ holds the card the recorded macOS exchange asked for, so
# the replay resolves the same hrefs the client did.
ENV.delete("SENTRY_DSN")

require "pathname"

ENV["PRO_TACTS_DATA_DIR"] = (Pathname.new(__dir__) / "fixtures").to_s

# Silence the request log; web.rb reads this when it is required.
require "logger"
require "pro_tacts"
ProTacts.config.access_logger = Logger.new(IO::NULL)

require "minitest/autorun"
