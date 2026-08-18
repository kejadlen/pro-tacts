
require "minitest/autorun"
require "logger"
require "stringio"

require "pro_tacts/debug_logger"

class DebugLoggerTest < Minitest::Test
  def setup
    @io = StringIO.new
    @logger = Logger.new(@io)
    @app = ProTacts::DebugLogger.new(echo_app, logger: @logger)
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
      "rack.input" => StringIO.new(body),
    }.merge(headers.transform_keys { "HTTP_#{it.to_s.upcase.tr('-', '_')}" })
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
      logger: Logger.new(StringIO.new),
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

  class OpenLogTest < Minitest::Test
    def test_appends_timestamped_lines_to_a_file_it_creates
      require "pathname"
      require "tmpdir"
      Dir.mktmpdir do |dir|
        path = Pathname.new(dir) / "nested" / "debug.log"
        logger = ProTacts::DebugLogger.open_log(path)
        logger.debug(">> PROPFIND / HTTP/1.1")

        assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3} >> PROPFIND \/ HTTP\/1.1\n/, File.read(path))
      end
    end
  end
end
