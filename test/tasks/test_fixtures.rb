require_relative "../test_helper"

require "pathname"
require "rack/test"
require "rake"
require "tmpdir"

require "pro_tacts/exchange_log"
require_relative "../pro_tacts/exchange_fixtures"

class FixturesTasksTest < Minitest::Test
  include Rack::Test::Methods

  CARD = "BEGIN:VCARD\r\nUID:new\r\nEND:VCARD\r\n"

  def setup
    @root = Pathname.new(Dir.mktmpdir("fixtures-extract"))
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  # Refuses everything, so every exchange is logged.
  def app
    @app ||= ProTacts::ExchangeLog.new(->(_env) { [412, {}, []] }, path: @root / "exchange.log", everything: false)
  end

  def test_the_request_is_written_as_a_step_without_what_identifies_the_tailnet
    put "/dav/addressbook/new.vcf", CARD,
      "CONTENT_TYPE" => "text/vcard", "HTTP_IF_MATCH" => '"abc"', "HTTP_USER_AGENT" => "AddressBookCore",
      "HTTP_TAILSCALE_USER_LOGIN" => "ada@example.com", "HTTP_TAILSCALE_USER_NAME" => "Ada"

    extract(exchange, @root / "07-put")

    assert_equal "PUT /dav/addressbook/new.vcf HTTP/1.0\nContent-Type: text/vcard\nIf-Match: \"abc\"\n\n#{CARD}\n",
      (@root / "07-put" / "request").binread
  end

  def test_the_step_replays_the_body_the_client_sent
    put "/dav/addressbook/new.vcf", CARD

    extract(exchange, @root / "07-put")

    assert_equal CARD, ExchangeFixtures.new(@root).parse_request("07-put").fetch(:body)
  end

  def test_a_request_file_already_there_is_left_alone
    put "/dav/addressbook/new.vcf", CARD
    step = @root / "07-put"
    step.mkpath
    (step / "request").write("recorded")

    assert_raises(SystemExit) { extract(exchange, step) }
    assert_equal "recorded", (step / "request").read
  end

  def test_an_exchange_no_log_holds_writes_nothing
    assert_raises(SystemExit) { extract("0123456789ab", @root / "07-put") }
    refute (@root / "07-put").exist?
  end

  private

  def exchange = last_request.env.fetch(ProTacts::ExchangeLog::ENV_KEY)

  # Runs fixtures:extract in a Rake application of its own, reading this
  # test's log as the configured one.
  def extract(id, step)
    config = ProTacts.config
    application = Rake.application
    overridden = ENV.to_h.slice("EXCHANGE", "STEP")

    ProTacts.config = ProTacts::Config.new("PRO_TACTS_EXCHANGE_LOG" => (@root / "exchange.log").to_s)
    ENV["EXCHANGE"] = id
    ENV["STEP"] = step.to_s
    Rake.application = Rake::Application.new
    load (Pathname.new(__dir__).parent.parent / "tasks" / "fixtures.rake").to_s
    capture_io { Rake.application["fixtures:extract"].invoke }
  ensure
    ProTacts.config = config
    Rake.application = application
    %w[EXCHANGE STEP].each { ENV[it] = overridden[it] }
  end
end
