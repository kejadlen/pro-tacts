# frozen_string_literal: true

require_relative "../test_helper"
require "rack/test"

require_relative "exchange_fixtures"
require "pro_tacts/web"

# Replays each recorded macOS Contacts request against the app and compares
# the response, byte for byte, with the recorded baseline. A failure means
# the responses drifted from what the working client session saw; either fix
# the drift or, if the change was deliberate, regenerate with `rake fixtures`.
class MacosExchangeTest < Minitest::Test
  include Rack::Test::Methods

  def app
    ProTacts::Web
  end

  ExchangeFixtures.steps.each do |step|
    define_method(:"test_#{step.name}") do
      request step.path, { method: step.method, input: step.body }.merge(ExchangeFixtures.env_for(step))

      expected = ExchangeFixtures.recorded_response(step)

      assert_equal expected.status, last_response.status
      expected.headers.each do |name, value|
        assert_equal value, last_response[name], name
      end
      assert_equal expected.body, last_response.body.chomp
    end
  end
end
