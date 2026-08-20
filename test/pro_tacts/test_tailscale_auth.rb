require_relative "../test_helper"
require "rack/test"

require "pro_tacts/tailscale_auth"

class TailscaleAuthTest < Minitest::Test
  include Rack::Test::Methods

  # Records what the middleware passed through, so a refused request can be
  # distinguished from one the app merely ignored.
  class Spy
    attr_reader :env

    def call(env)
      @env = env
      [200, { "Content-Type" => "text/plain" }, ["reached the app"]]
    end
  end

  def setup
    @spy = Spy.new
    @app = ProTacts::TailscaleAuth.new(@spy)
  end

  attr_reader :app

  def test_request_with_an_identity_reaches_the_app
    header "Tailscale-User-Login", "alpha@example.com"

    get "/"

    assert_equal 200, last_response.status
    assert_equal "reached the app", last_response.body
  end

  def test_identity_is_available_to_the_app
    header "Tailscale-User-Login", "alpha@example.com"

    get "/"

    assert_equal "alpha@example.com", @spy.env[ProTacts::TailscaleAuth::IDENTITY]
  end

  def test_request_without_an_identity_is_refused
    get "/"

    assert_equal 403, last_response.status
    assert_nil @spy.env
  end

  def test_request_with_an_empty_identity_is_refused
    header "Tailscale-User-Login", ""

    get "/"

    assert_equal 403, last_response.status
    assert_nil @spy.env
  end

  def test_request_with_a_blank_identity_is_refused
    header "Tailscale-User-Login", "   "

    get "/"

    assert_equal 403, last_response.status
    assert_nil @spy.env
  end

  def test_refusal_explains_itself_in_plain_text
    get "/"

    assert_equal "text/plain", last_response["Content-Type"]
    assert_includes last_response.body, "Tailscale"
  end

  # Every route is gated, not just the address book: an unauthenticated
  # request must not learn whether a path exists.
  def test_refusal_covers_every_path
    %w[/ /.well-known/carddav /dav/ /dav/principal/ /dav/addressbook/].each do |path|
      get path

      assert_equal 403, last_response.status, path
    end
  end
end
