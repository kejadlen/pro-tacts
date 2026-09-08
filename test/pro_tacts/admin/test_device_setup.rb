require_relative "../../test_helper"

require "rack/test"

require "pro_tacts/profile"
require "pro_tacts/web"

# GET /setup and the document it links to, exercised the way the other
# screens are: real requests through the Roda app. No store is touched —
# the profile is rendered from the request alone — so unlike the contacts
# pages these need no database standing behind them.
class AdminDeviceSetupTest < Minitest::Test
  include Rack::Test::Methods

  def app
    ProTacts::Web
  end

  def setup
    header "Tailscale-User-Login", "test@example.com"
    header "Host", "box.example.ts.net"
  end

  def test_screen_names_the_account_the_download_carries
    get "/setup"

    assert_equal 200, last_response.status
    assert_equal "text/html; charset=utf-8", last_response["Content-Type"]
    assert_includes last_response.body, "box.example.ts.net"
    assert_includes last_response.body, ProTacts::Profile::DEFAULT_NAME
    assert_includes last_response.body, "/setup/carddav.mobileconfig"
  end

  # The media type is what makes a device offer to install rather than
  # save, so it is the assertion that matters most here.
  def test_document_is_served_as_a_configuration_profile
    get "/setup/carddav.mobileconfig"

    assert_equal 200, last_response.status
    assert_equal "application/x-apple-aspen-config", last_response["Content-Type"]
    assert_includes last_response.body, "<string>com.apple.carddav.account</string>"
  end

  # The point of reading the hostname off the request: whatever address
  # the device reached us at is the address the account is provisioned
  # for.
  def test_document_names_the_host_the_request_arrived_on
    header "Host", "other.example.ts.net"
    get "/setup/carddav.mobileconfig"

    assert_includes last_response.body, "<string>other.example.ts.net</string>"
  end

  # Fresh per download (see Profile): a reinstall is a cold account, not
  # an update of the one already there.
  def test_each_download_carries_its_own_identifier
    get "/setup/carddav.mobileconfig"
    first = last_response.body
    get "/setup/carddav.mobileconfig"

    refute_equal first, last_response.body
    assert_includes first, ProTacts::Profile::IDENTIFIER_PREFIX
    assert_includes last_response.body, ProTacts::Profile::IDENTIFIER_PREFIX
  end
end
