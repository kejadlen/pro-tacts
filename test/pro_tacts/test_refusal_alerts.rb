require_relative "../test_helper"
require "rack/test"

require "pro_tacts/refusal_alerts"

class RefusalAlertsTest < Minitest::Test
  include Sentry::TestHelper
  include SentryMessages
  include Rack::Test::Methods

  def setup
    setup_sentry
    @status = 200
  end

  def teardown
    teardown_sentry_test
  end

  def app
    ProTacts::RefusalAlerts.new(->(_env) { [@status, {}, [""]] })
  end

  def dav(path, method: "PUT")
    request path, method:, ProTacts::ExchangeLog::ENV_KEY => "abc123"
  end

  def test_each_refusal_warns
    [403, 404, 410, 412].each do |status|
      @status = status

      dav "/dav/addressbook/"
    end

    assert_equal 4, sentry_events.length
    assert(sentry_events.all? { it.level == :warning })
  end

  def test_other_statuses_are_quiet
    [200, 201, 207, 400, 401, 500].each do |status|
      @status = status

      dav "/dav/addressbook/"
    end

    assert_empty sentry_events
  end

  def test_a_refusal_repeated_across_cards_is_one_group
    @status = 412

    dav "/dav/addressbook/aiden.vcf"
    dav "/dav/addressbook/bea.vcf"

    assert_equal [%w[PUT /dav/addressbook/{id}.vcf 412]] * 2, sentry_events.map(&:fingerprint)
    assert_equal "PUT /dav/addressbook/{id}.vcf answered 412 Precondition Failed", sentry_messages.first
  end

  def test_the_card_a_refusal_names_is_a_tag
    @status = 412

    dav "/dav/addressbook/aiden.vcf"
    dav "/dav/addressbook/"

    assert_equal ["aiden", nil], sentry_events.map { it.tags[:card] }
  end

  def test_the_method_and_status_split_groups
    @status = 412
    dav "/dav/addressbook/aiden.vcf", method: "PUT"
    dav "/dav/addressbook/aiden.vcf", method: "DELETE"
    @status = 404
    dav "/dav/addressbook/aiden.vcf", method: "DELETE"

    assert_equal 3, sentry_events.map(&:fingerprint).uniq.length
  end

  def test_an_exchange_the_log_did_not_mark_is_quiet
    @status = 404

    get "/contacts/nope"

    assert_empty sentry_events
  end
end
