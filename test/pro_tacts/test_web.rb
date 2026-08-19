
require_relative "../test_helper"
require "rack/test"
require "tmpdir"

require "pro_tacts/config"
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

  def test_get_unknown_contact_is_404
    get "/dav/addressbook/nope.vcf"

    assert_equal 404, last_response.status
    assert_equal "Not Found", last_response.body
  end

  # Swaps in a throwaway contacts directory so the multi-contact routes
  # can be exercised without touching the exchange fixture data.
  def with_contacts(files)
    Dir.mktmpdir do |dir|
      files.each { |name, content| File.write(File.join(dir, name), content) }
      original = ProTacts.config
      ProTacts.config = ProTacts::Config.new({
        "RACK_ENV" => "test",
        "PRO_TACTS_CONTACTS_DIR" => dir,
      })
      begin
        yield
      ensure
        ProTacts.config = original
      end
    end
  end

  def etag_only_propfind
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <A:propfind xmlns:A="DAV:">
        <A:prop>
          <A:getetag/>
        </A:prop>
      </A:propfind>
    XML
  end

  def multiget(*ids)
    hrefs = ids.map { "<A:href xmlns:A=\"DAV:\">/dav/addressbook/#{it}.vcf</A:href>" }.join("\n    ")

    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <C:addressbook-multiget xmlns:C="urn:ietf:params:xml:ns:carddav">
        <A:prop xmlns:A="DAV:">
          <A:getetag/>
          <C:address-data/>
        </A:prop>
        #{hrefs}
      </C:addressbook-multiget>
    XML
  end

  def test_listing_and_multiget_serve_every_contact_on_disk
    with_contacts({
      "aiden.kdl" => "name \"Aiden\"",
      "znorth.kdl" => "name \"Zed\"",
    }) do
      request "/dav/addressbook/", method: "PROPFIND", "HTTP_DEPTH" => "1", input: etag_only_propfind

      assert_equal 207, last_response.status
      assert_includes last_response.body, "/dav/addressbook/aiden.vcf"
      assert_includes last_response.body, "/dav/addressbook/znorth.vcf"

      request "/dav/addressbook/", method: "REPORT", input: multiget("aiden", "znorth")

      assert_equal 207, last_response.status
      assert_includes last_response.body, "FN:Aiden"
      assert_includes last_response.body, "UID:aiden"
      assert_includes last_response.body, "FN:Zed"
      assert_includes last_response.body, "UID:znorth"
    end
  end

  def test_multiget_reports_unknown_hrefs_as_404
    with_contacts({"aiden.kdl" => "name \"Aiden\""}) do
      request "/dav/addressbook/", method: "REPORT", input: multiget("aiden", "nope")

      assert_equal 207, last_response.status
      assert_includes last_response.body, "FN:Aiden"
      assert_includes last_response.body, "/dav/addressbook/nope.vcf"
      assert_includes last_response.body, "HTTP/1.1 404 Not Found"
    end
  end

  def test_multiget_escapes_vcard_content_for_xml
    with_contacts({"aiden.kdl" => "name \"A & B <Team>\""}) do
      request "/dav/addressbook/", method: "REPORT", input: multiget("aiden")

      assert_equal 207, last_response.status
      assert_includes last_response.body, "FN:A &amp; B &lt;Team&gt;"
    end
  end

  def test_sync_collection_returns_etags_only
    with_contacts({"aiden.kdl" => "name \"Aiden\""}) do
      request "/dav/addressbook/", method: "REPORT", input: <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <A:sync-collection xmlns:A="DAV:">
          <A:sync-token>http://pro-tacts/sync/1</A:sync-token>
          <A:sync-level>1</A:sync-level>
          <A:prop>
            <A:getetag/>
          </A:prop>
        </A:sync-collection>
      XML

      assert_equal 207, last_response.status
      assert_includes last_response.body, "/dav/addressbook/aiden.vcf"
      assert_includes last_response.body, "getetag"
      refute_includes last_response.body, "address-data"
    end
  end
end
