# frozen_string_literal: true

require "minitest/autorun"
require "rack/test"

require "pro_tacts/web"

class WebTest < Minitest::Test
  include Rack::Test::Methods

  def app
    ProTacts::Web
  end

  def test_hello
    get "/hello"

    assert_equal 200, last_response.status
    assert_equal "Hello!", last_response.body
  end
end
