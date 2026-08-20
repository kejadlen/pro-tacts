
require_relative "../test_helper"
require "digest"
require "fileutils"
require "pathname"
require "rack/test"
require "tmpdir"

require "pro_tacts/config"
require "pro_tacts/web"

class WebTest < Minitest::Test
  include Rack::Test::Methods

  def app
    ProTacts::Web
  end

  # Every request needs a Tailscale identity; the middleware refuses without
  # one. Tests for that refusal are in TailscaleAuthTest.
  def setup
    header "Tailscale-User-Login", "test@example.com"
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
    assert_equal %("#{Digest::SHA256.hexdigest(last_response.body)}"), last_response["ETag"]
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

  # Guards the wiring rather than the middleware: mounted in the stack, below
  # the auth gate, pointed at the configured directory.
  def test_an_unhandled_request_is_kept_on_disk
    directory = ProTacts.config.unhandled_dir
    FileUtils.rm_rf(directory)

    get "/dav/addressbook/no-such-contact.vcf"

    assert_equal 404, last_response.status

    captured = Pathname.new(directory).glob("*/request").map(&:read)

    assert_equal 1, captured.size
    assert_includes captured.first, "/dav/addressbook/no-such-contact.vcf"
  ensure
    FileUtils.rm_rf(directory)
  end

  def test_a_refused_request_is_not_kept_on_disk
    directory = ProTacts.config.unhandled_dir
    FileUtils.rm_rf(directory)

    header "Tailscale-User-Login", ""
    get "/dav/addressbook/no-such-contact.vcf"

    assert_equal 403, last_response.status
    refute Pathname.new(directory).exist?, "a refused request should leave nothing behind"
  ensure
    FileUtils.rm_rf(directory)
  end

  def test_get_unknown_contact_is_404
    get "/dav/addressbook/nope.vcf"

    assert_equal 404, last_response.status
    assert_equal "Not Found", last_response.body
  end

  # Swaps in a throwaway data directory so the multi-contact routes can
  # be exercised without touching the exchange fixture data.
  def with_contacts(files)
    Dir.mktmpdir do |dir|
      contacts_dir = Pathname.new(dir) / "contacts"
      Dir.mkdir(contacts_dir)
      files.each { |name, content| File.write(contacts_dir / name, content) }
      original = ProTacts.config
      ProTacts.config = ProTacts::Config.new({
        "RACK_ENV" => "test",
        "PRO_TACTS_DATA_DIR" => dir,
      })
      begin
        yield contacts_dir
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

  def addressbook_query
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <C:addressbook-query xmlns:C="urn:ietf:params:xml:ns:carddav">
        <A:prop xmlns:A="DAV:">
          <A:getetag/>
        </A:prop>
      </C:addressbook-query>
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

  # RFC 6352 section 8.6 defines addressbook-query, which this server does
  # not implement. Before the DAV:supported-report precondition was enforced
  # it fell through to the multiget branch, found no hrefs, and answered with
  # an empty 207 that read as a successful empty address book.
  def test_unsupported_report_is_refused_rather_than_answered_emptily
    directory = ProTacts.config.unhandled_dir
    FileUtils.rm_rf(directory)

    with_contacts({"aiden.kdl" => "name \"Aiden\""}) do
      request "/dav/addressbook/", method: "REPORT", input: addressbook_query

      assert_equal 403, last_response.status
      assert_includes last_response.body, "<d:supported-report/>"
      refute_includes last_response.body, "multistatus"

      # The refusal is what makes the ask visible; an empty 207 left nothing.
      captured = Pathname.new(directory).glob("*/request").map(&:read)

      assert_equal 1, captured.size
      assert_includes captured.first, "addressbook-query"
    end
  ensure
    FileUtils.rm_rf(directory)
  end

  def test_etags_agree_across_listing_multiget_and_get
    with_contacts({"aiden.kdl" => "name \"Aiden\""}) do
      request "/dav/addressbook/", method: "PROPFIND", "HTTP_DEPTH" => "1", input: etag_only_propfind
      etag = last_response.body[%r{<d:getetag>(.+)</d:getetag>}, 1]

      get "/dav/addressbook/aiden.vcf"
      assert_equal etag, last_response["ETag"]

      request "/dav/addressbook/", method: "REPORT", input: multiget("aiden")
      assert_includes last_response.body, "<d:getetag>#{etag}</d:getetag>"
    end
  end

  def test_a_changed_card_changes_its_etag_and_the_collection_tags
    with_contacts({"aiden.kdl" => "name \"Aiden\""}) do |contacts_dir|
      read_tags = lambda {
        request "/dav/addressbook/", method: "PROPFIND"
        [last_response.body[%r{<d:getetag>(.+)</d:getetag>}, 1],
         last_response.body[%r{<cs:getctag>(.+)</cs:getctag>}, 1],
         last_response.body[%r{<d:sync-token>(.+)</d:sync-token>}, 1]]
      }

      before = read_tags.call
      assert_equal before, read_tags.call # stable across requests

      File.write(contacts_dir / "aiden.kdl", "name \"Aiden Smith\"")
      after = read_tags.call

      before.zip(after).each { refute_equal it.first, it.last }
    end
  end
end
