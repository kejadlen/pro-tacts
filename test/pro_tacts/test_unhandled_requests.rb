require_relative "../test_helper"
require "rack/test"
require "tmpdir"

require "pro_tacts/unhandled_requests"

class UnhandledRequestsTest < Minitest::Test
  include Rack::Test::Methods

  # Returns whatever status the test asks for, so each case can drive the
  # capture decision directly.
  class Stub
    attr_accessor :status

    def initialize
      @status = 200
    end

    def call(_env)
      [@status, { "Content-Type" => "text/plain" }, ["body from the app"]]
    end
  end

  def setup
    @directory = Pathname.new(Dir.mktmpdir("unhandled"))
    @stub = Stub.new
    @app = ProTacts::UnhandledRequests.new(@stub, directory: @directory)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  attr_reader :app

  def captures
    @directory.children.select(&:directory?)
  end

  def test_successful_requests_are_not_captured
    @stub.status = 200

    get "/dav/addressbook/"

    assert_empty captures
  end

  def test_a_404_is_captured
    @stub.status = 404

    get "/dav/unknown/"

    assert_equal 1, captures.size
  end

  def test_a_server_error_is_captured
    @stub.status = 500

    get "/dav/addressbook/"

    assert_equal 1, captures.size
  end

  # An unsupported REPORT type. TailscaleAuth refuses unauthenticated
  # requests above this middleware, so a 403 reaching it is always the app
  # saying it routed the request and will not serve it.
  def test_a_403_from_the_app_is_captured
    @stub.status = 403

    request "/dav/addressbook/", method: "REPORT", input: "<addressbook-query/>"

    assert_equal 1, captures.size
  end

  def test_capture_records_the_request_verbatim
    @stub.status = 404

    request "/dav/addressbook/", method: "REPORT", input: "<sync-collection/>",
      "CONTENT_TYPE" => "text/xml", "HTTP_DEPTH" => "1"

    recorded = (captures.first / "request").read

    assert_match(%r{\AREPORT /dav/addressbook/ HTTP/1\.\d\n}, recorded)
    assert_includes recorded, "Depth: 1"
    assert_includes recorded, "Content-Type: text/xml"
    assert_includes recorded, "<sync-collection/>"
  end

  def test_capture_records_the_response
    @stub.status = 404

    get "/dav/unknown/"

    recorded = (captures.first / "response").read

    assert_includes recorded, "404"
    assert_includes recorded, "Content-Type: text/plain"
    assert_includes recorded, "body from the app"
  end

  # The whole point of the format: a capture drops into the fixture suite.
  def test_capture_uses_the_fixture_layout
    @stub.status = 404

    get "/dav/unknown/"

    assert_equal %w[request response], captures.first.children.map { it.basename.to_s }.sort
  end

  def test_the_app_still_sees_its_own_body
    @stub.status = 404

    get "/dav/unknown/"

    assert_equal "body from the app", last_response.body
  end

  def test_a_repeated_request_is_captured_once
    @stub.status = 404

    3.times { get "/dav/unknown/" }

    assert_equal 1, captures.size
  end

  def test_different_requests_are_captured_separately
    @stub.status = 404

    get "/dav/unknown/"
    get "/dav/other/"

    assert_equal 2, captures.size
  end

  # Same path, different body: the multiget case, where what was asked for
  # is the part that matters.
  def test_the_body_distinguishes_captures
    @stub.status = 404

    request "/dav/addressbook/", method: "REPORT", input: "<one/>"
    request "/dav/addressbook/", method: "REPORT", input: "<two/>"

    assert_equal 2, captures.size
  end

  def test_an_unwritable_directory_does_not_break_the_response
    app = ProTacts::UnhandledRequests.new(@stub, directory: @directory / "nested" / "deep")
    @stub.status = 404

    session = Rack::Test::Session.new(Rack::MockSession.new(app))
    session.get "/dav/unknown/"

    assert_equal 404, session.last_response.status
  end
end
