
# The fixtures directory serves as the data directory: its contacts/
# holds the card the recorded macOS exchange asked for, so the replay
# resolves the same hrefs the client did. Nothing else is set up:
# requiring the app has no side effects, and config.ru never runs here.
require "pathname"

ENV["PRO_TACTS_DATA_DIR"] = (Pathname.new(__dir__) / "fixtures").to_s

require "minitest/autorun"
