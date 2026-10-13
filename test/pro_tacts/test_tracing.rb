require_relative "../test_helper"

require "rack/test"

require "pro_tacts/web"

# Tracing's scrub, not trace_ignore_status_codes, decides which
# requests Sentry keeps a transaction for.
class TracingTest < Minitest::Test
  include Rack::Test::Methods
  include SentryTracing

  def app
    traced(ProTacts::Web)
  end

  def setup
    setup_sentry_tracing
    header "Remote-User", "test@example.com"
  end

  def teardown
    teardown_sentry_test
  end

  def test_a_page_is_traced_by_its_route
    get "/"

    assert_equal ["GET /"], sentry_events.grep(Sentry::TransactionEvent).map(&:transaction)
  end

  def test_a_not_found_is_not_traced
    get "/no-such-page"

    assert_equal 404, last_response.status
    assert_empty sentry_events.grep(Sentry::TransactionEvent)
  end
end
