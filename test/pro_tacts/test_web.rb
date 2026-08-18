
require_relative "../test_helper"
require "rack/test"

require "pro_tacts/web"

class WebTest < Minitest::Test
  include Rack::Test::Methods

  def app
    ProTacts::Web
  end

  def test_options_returns_dav_headers
    options "/dav/"

    assert_equal 200, last_response.status
    assert_equal "addressbook", last_response["DAV"]
    assert_includes last_response["Allow"], "OPTIONS"
    assert_includes last_response["Allow"], "PROPFIND"
  end

  def test_propfind_root
    request "/", method: "PROPFIND"

    assert_equal 207, last_response.status
    assert_equal "text/xml", last_response["Content-Type"]
    assert_includes last_response.body, "current-user-principal"
    assert_includes last_response.body, "/dav/principal/"
  end

  def test_well_known_carddav_redirects_to_principal
    get "/.well-known/carddav"

    assert_equal 301, last_response.status
    assert_equal "/dav/principal/", last_response["Location"]
  end

  def test_propfind_well_known_carddav
    request "/.well-known/carddav", method: "PROPFIND"

    assert_equal 207, last_response.status
    assert_equal "text/xml", last_response["Content-Type"]
    assert_includes last_response.body, "current-user-principal"
    assert_includes last_response.body, "/dav/principal/"
  end

  def test_propfind_principal
    request "/dav/principal/", method: "PROPFIND"

    assert_equal 207, last_response.status
    assert_equal "text/xml", last_response["Content-Type"]
    assert_includes last_response.body, "multistatus"
    assert_includes last_response.body, "/dav/addressbook/"
  end

  def test_propfind_addressbook
    request "/dav/addressbook/", method: "PROPFIND"

    assert_equal 207, last_response.status
    assert_equal "text/xml", last_response["Content-Type"]
    assert_includes last_response.body, "multistatus"
    assert_includes last_response.body, ".vcf"
  end

  def test_get_contact
    get "/dav/addressbook/AB12C345-6789-0DEF-1234-567890ABCDEF.vcf"

    assert_equal 200, last_response.status
    assert_equal "text/vcard; charset=utf-8", last_response["Content-Type"]
    assert_equal %("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"), last_response["ETag"]
    assert_includes last_response.body, "BEGIN:VCARD"
    assert_includes last_response.body, "END:VCARD"
  end

  def test_propfind_addressbook_includes_ctag
    request "/dav/addressbook/", method: "PROPFIND"

    assert_equal 207, last_response.status
    assert_includes last_response.body, "http://calendarserver.org/ns/"
    assert_includes last_response.body, "getctag"
  end

  def test_propfind_addressbook_depth_0_excludes_contacts
    request "/dav/addressbook/", method: "PROPFIND", "HTTP_DEPTH" => "0"

    assert_equal 207, last_response.status
    assert_includes last_response.body, "getctag"
    refute_includes last_response.body, "AB12C345-6789-0DEF-1234-567890ABCDEF.vcf"
  end

  def test_propfind_addressbook_depth_1_includes_contacts
    request "/dav/addressbook/", method: "PROPFIND", "HTTP_DEPTH" => "1"

    assert_equal 207, last_response.status
    assert_includes last_response.body, "getctag"
    assert_includes last_response.body, "AB12C345-6789-0DEF-1234-567890ABCDEF.vcf"
  end
end
