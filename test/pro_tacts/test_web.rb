# frozen_string_literal: true

require "minitest/autorun"
require "rack/test"

require "pro_tacts/web"

class WebTest < Minitest::Test
  include Rack::Test::Methods

  def app
    ProTacts::Web
  end

  def test_options_returns_dav_headers
    options "/"

    assert_equal 200, last_response.status
    assert_equal "1, 3, addressbook", last_response["DAV"]
    assert_includes last_response["Allow"], "OPTIONS"
    assert_includes last_response["Allow"], "PROPFIND"
  end

  def test_well_known_carddav_redirects_to_principal
    get "/.well-known/carddav"

    assert_equal 301, last_response.status
    assert_equal "/principal/", last_response["Location"]
  end

  def test_propfind_principal
    request "/principal/", method: "PROPFIND"

    assert_equal 207, last_response.status
    assert_equal "text/xml", last_response["Content-Type"]
    assert_includes last_response.body, "multistatus"
    assert_includes last_response.body, "/addressbook/"
  end

  def test_propfind_addressbook
    request "/addressbook/", method: "PROPFIND"

    assert_equal 207, last_response.status
    assert_equal "text/xml", last_response["Content-Type"]
    assert_includes last_response.body, "multistatus"
    assert_includes last_response.body, ".vcf"
  end

  def test_get_contact
    get "/addressbook/test-contact.vcf"

    assert_equal 200, last_response.status
    assert_equal "text/vcard", last_response["Content-Type"]
    assert_includes last_response.body, "BEGIN:VCARD"
    assert_includes last_response.body, "END:VCARD"
  end
end
