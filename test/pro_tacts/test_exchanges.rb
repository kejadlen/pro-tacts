require_relative "../test_helper"
require_relative "../fixture_data"
require "pathname"
require "rack/test"

require_relative "exchange_fixtures"
require "pro_tacts/web"

# Replays each recorded client session against the app and compares
# every response, byte for byte, with the recorded baseline. A failure
# means the responses drifted from what a working client session saw;
# either fix the drift or, if the change was deliberate, regenerate with
# `rake fixtures`.
#
# The steps of one recording run in sorted order against one freshly
# seeded store, in a single test: the session is a conversation, and a
# step that writes has to be able to change what the steps after it see.
# A failure stops that replay at the first divergent step — the steps
# after it would be measuring a state the real session never produced.
#
# The two recordings are independent conversations and get a store each,
# so what the iOS session deletes is still there for the macOS one.
class ExchangesTest < Minitest::Test
  include Rack::Test::Methods

  def app
    ProTacts::Web
  end

  def test_the_recorded_macos_session_replays_in_order
    replay(ExchangeFixtures::MACOS)
  end

  def test_the_recorded_ios_session_replays_in_order
    replay(ExchangeFixtures::IOS)
  end

  private

  def replay(recording)
    # A store of its own so the writes a session may make never touch the
    # one the rest of the suite reads, built fresh so a replay never depends
    # on what a previous run left behind.
    directory = Pathname.new(__dir__).parent.parent / "tmp" / recording.directory.basename
    store = FixtureData.install(directory)
    original = ProTacts::Web.store
    ProTacts::Web.store = store

    recording.steps.each do |step|
      request step.path, { method: step.method, input: step.body }.merge(recording.env_for(step))

      expected = recording.recorded_response(step)

      assert_equal expected.status, last_response.status, "#{step.name}: status"
      expected.headers.each do |name, value|
        assert_equal value, last_response[name], "#{step.name}: #{name}"
      end
      assert_equal expected.body, last_response.body.chomp, "#{step.name}: body"
    end
  ensure
    ProTacts::Web.store = original
    store&.close
  end
end
