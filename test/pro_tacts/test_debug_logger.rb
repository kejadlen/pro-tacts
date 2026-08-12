# frozen_string_literal: true

require "minitest/autorun"
require "stringio"

require "pro_tacts/debug_logger"

class DebugLoggerTest < Minitest::Test
  def setup
    @io = StringIO.new
    @app = ProTacts::DebugLogger.new(echo_app, io: @io)
  end

  # Echoes a fixed response so assertions can target what the logger adds.
  def echo_app
    body = ["<multistatus/>"]
    ->(_env) { [207, { "Content-Type" => "text/xml", "ETag" => %("abc") }, body] }
  end

  def env(body: "", **headers)
    {
      "REQUEST_METHOD" => "PROPFIND",
      "PATH_INFO" => "/dav/addressbook/",
      "QUERY_STRING" => "",
      "SERVER_PROTOCOL" => "HTTP/1.1",
      "rack.input" => StringIO.new(body)
    }.merge(headers.transform_keys { |k| "HTTP_#{k.to_s.upcase.tr('-', '_')}" })
  end

  def test_dumps_request_line_with_method_path_and_protocol
    @app.call(env)

    assert_includes @io.string, ">> PROPFIND /dav/addressbook/ HTTP/1.1"
  end

  def test_dumps_request_headers
    @app.call(env(Depth: "1"))

    assert_includes @io.string, ">> Depth: 1"
  end

  def test_dumps_request_body_with_every_line_prefixed
    @app.call(env(body: "<propfind>\n  <prop/>\n</propfind>"))

    assert_includes @io.string, ">> <propfind>"
    assert_includes @io.string, ">>   <prop/>"
    assert_includes @io.string, ">> </propfind>"
  end

  def test_request_body_is_still_readable_by_the_app
    read = nil
    app = ProTacts::DebugLogger.new(
      ->(e) { read = e["rack.input"].read; [200, {}, [""]] },
      io: StringIO.new
    )

    app.call(env(body: "<x/>"))

    assert_equal "<x/>", read
  end

  def test_omits_request_body_line_when_there_is_no_body
    @app.call(env)

    refute_includes @io.string, ">> \n"
  end

  def test_dumps_response_status_headers_and_body
    @app.call(env)

    assert_includes @io.string, "<< 207 Multi-Status"
    assert_includes @io.string, "<< Content-Type: text/xml"
    assert_includes @io.string, "<< ETag: \"abc\""
    assert_includes @io.string, "<< <multistatus/>"
  end

  def test_returns_the_response_intact
    status, headers, body = @app.call(env)

    assert_equal 207, status
    assert_equal "text/xml", headers["Content-Type"]
    assert_equal ["<multistatus/>"], body
  end
end
