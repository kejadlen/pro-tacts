require_relative "../test_helper"
require "rack/test"
require "tmpdir"

require "pro_tacts/exchange_log"

class ExchangeLogTest < Minitest::Test
  include Sentry::TestHelper
  include SentryMessages
  include Rack::Test::Methods

  # Answers whatever the test asks for, so each case drives the logging
  # decision directly. It reads the body first, as the DAV routes do.
  class Stub
    attr_accessor :status, :report, :error

    def initialize
      @status = 200
    end

    def call(env)
      env["rack.input"]&.read
      Sentry.capture_message("reported") if @report
      raise @error if @error

      [@status, { "content-type" => "text/plain" }, ["body from the app"]]
    end
  end

  def setup
    setup_sentry
    @directory = Pathname.new(Dir.mktmpdir("exchange-log"))
    @stub = Stub.new
    @everything = false
  end

  def teardown
    teardown_sentry_test
    FileUtils.remove_entry(@directory)
  end

  def app
    @app ||= ProTacts::ExchangeLog.new(@stub, path: @directory / "exchange.log", everything: @everything)
  end

  # Logger heads a new file with a comment line of its own.
  def logged
    path = @directory / "exchange.log"
    path.exist? ? path.readlines.reject { it.start_with?("#") }.join : ""
  end

  def test_a_successful_exchange_is_not_logged
    request "/dav/addressbook/", method: "PROPFIND"

    assert_empty logged
  end

  def test_a_client_or_server_error_is_logged
    [400, 403, 404, 410, 412, 500].each do |status|
      @stub.status = status

      request "/dav/addressbook/", method: "PROPFIND"

      assert_includes logged, "<< #{status}", status
    end
  end

  # An unauthenticated request is refused at the identity gate, and its
  # body came from outside the tailnet.
  def test_a_401_is_not_logged
    @stub.status = 401

    request "/dav/addressbook/", method: "PROPFIND"

    assert_empty logged
  end

  # An arrival report on a PUT that succeeded: the alert carries an
  # exchange id, so the exchange has to be there to read.
  def test_an_exchange_that_reported_to_sentry_is_logged_though_it_succeeded
    @stub.status = 201
    @stub.report = true

    put "/dav/addressbook/new.vcf", "BEGIN:VCARD"

    assert_includes logged, "<< 201 Created"
  end

  def test_an_exchange_that_raised_is_logged_and_still_raises
    @stub.error = RuntimeError.new("boom")

    assert_raises(RuntimeError) do
      request "/dav/addressbook/", method: "REPORT", input: "<nonsense/>"
    end

    assert_includes logged, ">> REPORT /dav/addressbook/"
    assert_includes logged, "!! RuntimeError: boom"
  end

  def test_the_request_is_logged_whole
    @stub.status = 404

    request "/dav/addressbook/", method: "REPORT", input: "<sync-collection>\n  <sync-token/>\n</sync-collection>",
      "CONTENT_TYPE" => "text/xml", "HTTP_DEPTH" => "1"

    assert_match(%r{>> REPORT /dav/addressbook/ HTTP/1\.\d$}, logged)
    assert_includes logged, ">> Depth: 1"
    assert_includes logged, ">> Content-Type: text/xml"
    assert_includes logged, ">> <sync-collection>"
    assert_includes logged, ">>   <sync-token/>"
  end

  def test_the_response_is_logged_whole
    @stub.status = 404

    get "/dav/addressbook/nope.vcf"

    assert_includes logged, "<< 404 Not Found"
    assert_includes logged, "<< content-type: text/plain"
    assert_includes logged, "<< body from the app"
  end

  def test_every_line_carries_the_id_sentry_was_given
    @stub.status = 412
    @stub.report = true

    put "/dav/addressbook/new.vcf", "BEGIN:VCARD\r\nEND:VCARD\r\n"

    id = sentry_events.last.tags.fetch(:exchange)

    refute_empty logged
    logged.each_line do |line|
      assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3} #{id} (>>|<<) /, line)
    end
  end

  def test_the_client_still_gets_the_whole_response
    @stub.status = 404

    get "/dav/addressbook/nope.vcf"

    assert_equal 404, last_response.status
    assert_equal "body from the app", last_response.body
  end

  def test_admin_traffic_is_not_logged
    @stub.status = 404

    get "/contacts/nope"
    post "/contacts"

    assert_empty logged
  end

  def test_a_dav_verb_to_any_path_is_logged
    @stub.status = 404

    request "/nowhere", method: "PROPFIND"

    assert_includes logged, ">> PROPFIND /nowhere"
  end

  def test_everything_logs_a_successful_exchange_too
    @everything = true

    request "/", method: "PROPFIND"

    assert_includes logged, "<< 200 OK"
  end

  def test_a_body_that_is_not_utf_8_logs_beside_one_that_is
    @stub.status = 412
    app
    @stub.define_singleton_method(:call) { |_env| [412, {}, ["Zoë"]] }

    put "/dav/addressbook/new.vcf", "\xFF\xFE".b

    assert_includes logged.b, "<< Zoë".b
  end
end
