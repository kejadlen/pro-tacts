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

  def identify(login: "alpha@example.com", name: "Alpha Chen")
    header "Tailscale-User-Login", login
    header "Tailscale-User-Name", name
  end

  def identity
    ProTacts::TailscaleAuth.identity(@spy.env)
  end

  def test_request_with_an_identity_reaches_the_app
    identify

    get "/"

    assert_equal 200, last_response.status
    assert_equal "reached the app", last_response.body
  end

  def test_the_app_can_read_who_got_through
    identify

    get "/"

    assert_equal ProTacts::TailscaleAuth::Identity.new(login: "alpha@example.com", name: "Alpha Chen"), identity
  end

  def test_request_without_an_identity_is_refused
    get "/"

    assert_equal 403, last_response.status
    assert_nil @spy.env
  end

  def test_request_with_an_empty_login_is_refused
    identify(login: "")

    get "/"

    assert_equal 403, last_response.status
    assert_nil @spy.env
  end

  def test_request_with_a_blank_login_is_refused
    identify(login: "   ")

    get "/"

    assert_equal 403, last_response.status
    assert_nil @spy.env
  end

  def test_request_without_a_name_is_refused
    header "Tailscale-User-Login", "alpha@example.com"

    get "/"

    assert_equal 403, last_response.status
    assert_nil @spy.env
  end

  def test_request_with_a_blank_name_is_refused
    identify(name: "   ")

    get "/"

    assert_equal 403, last_response.status
    assert_nil @spy.env
  end

  # What Go's mime.QEncoding writes for a non-ASCII value, which is how
  # serve sends one.
  def test_a_q_encoded_name_is_decoded
    identify(name: "=?utf-8?q?Zo=C3=AB_Chen?=")

    get "/"

    assert_equal "Zoë Chen", identity.name
  end

  def test_a_q_encoded_login_is_decoded
    identify(login: "=?utf-8?q?zo=C3=AB@example.com?=")

    get "/"

    assert_equal "zoë@example.com", identity.login
  end

  def test_whitespace_between_encoded_words_is_dropped
    identify(name: "=?utf-8?q?Zo=C3=AB?= =?utf-8?q?_Chen?=")

    get "/"

    assert_equal "Zoë Chen", identity.name
  end

  def test_whitespace_around_plain_text_is_kept
    identify(name: "Dr =?utf-8?q?Zo=C3=AB?= Chen")

    get "/"

    assert_equal "Dr Zoë Chen", identity.name
  end

  def test_a_b_encoded_name_is_decoded
    identify(name: "=?UTF-8?B?Wm/DqyBDaGVu?=")

    get "/"

    assert_equal "Zoë Chen", identity.name
  end

  def test_a_name_in_another_charset_is_refused
    identify(name: "=?iso-8859-1?q?Zo=EB?=")

    get "/"

    assert_equal 403, last_response.status
    assert_nil @spy.env
  end

  def test_a_name_that_decodes_to_invalid_utf8_is_refused
    identify(name: "=?utf-8?q?Zo=EB?=")

    get "/"

    assert_equal 403, last_response.status
    assert_nil @spy.env
  end

  def test_a_malformed_b_word_is_refused
    identify(name: "=?utf-8?b?not*base64?=")

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
