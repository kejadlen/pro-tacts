
require_relative "../test_helper"
require "digest"
require "fileutils"
require "pathname"
require "rack/test"
require "tmpdir"

require "pro_tacts/config"
require "pro_tacts/store"
require "pro_tacts/web"

class WebTest < Minitest::Test
  include CapturingSentry
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

  ## PUT

  # One PUT, so each test reads as a client's request rather than as
  # Rack env assembly.
  def put_request(id, body, headers = {})
    request "/dav/addressbook/#{id}.vcf", { method: "PUT", input: body }.merge(headers)
  end

  VCARD = "text/vcard"

  # RFC 6352 section 6.3.2: a PUT to an unmapped URI creates, and the
  # strong ETag comes back because the stored bytes are the submitted
  # bytes — the one case section 6.3.2.3 lets a client rely on it.
  def test_put_creates_a_contact
    card = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:New\r\nUID:new\r\nEND:VCARD\r\n"

    with_contacts({}) do |store|
      put_request "new", card, "CONTENT_TYPE" => VCARD, "HTTP_IF_NONE_MATCH" => "*"

      assert_equal 201, last_response.status
      assert_equal %("#{Digest::SHA256.hexdigest(card)}"), last_response["ETag"]
      assert_empty last_response.body

      get "/dav/addressbook/new.vcf"
      assert_equal card, last_response.body

      # The change-log entry a sync token counts on landed with the card.
      change = store.changes.last
      assert_equal "new", change.card_id
      assert_equal "put", change.action
    end
  end

  def test_put_with_if_none_match_star_refuses_an_existing_card
    with_contacts({"aiden" => "Aiden"}) do
      get "/dav/addressbook/aiden.vcf"
      served = last_response.body

      put_request "aiden", card("aiden", "Aiden Smith"),
        "CONTENT_TYPE" => VCARD, "HTTP_IF_NONE_MATCH" => "*"

      assert_equal 412, last_response.status

      get "/dav/addressbook/aiden.vcf"
      assert_equal served, last_response.body
    end
  end

  # If-None-Match is the client's SHOULD, not the server's requirement:
  # a bare PUT to an unmapped URI creates all the same (RFC 6352
  # section 6.3.2).
  def test_put_without_a_conditional_creates
    with_contacts({}) do
      put_request "new", card("new", "New"), "CONTENT_TYPE" => VCARD

      assert_equal 201, last_response.status
    end
  end

  def test_put_with_the_current_etag_updates
    with_contacts({"aiden" => "Aiden"}) do
      get "/dav/addressbook/aiden.vcf"
      stale = last_response["ETag"]

      updated = card("aiden", "Aiden Smith")
      put_request "aiden", updated, "CONTENT_TYPE" => VCARD, "HTTP_IF_MATCH" => stale

      assert_equal 204, last_response.status
      etag = %("#{Digest::SHA256.hexdigest(updated)}")
      assert_equal etag, last_response["ETag"]

      # A bodyless status must carry neither header: Rack 3's lint rejects
      # both on a 204, and `rake dev` runs under it.
      assert_nil last_response["Content-Type"]
      assert_nil last_response["Content-Length"]

      # The tag the PUT returned is the one every read now reports, which
      # is what lets a client keep syncing against its own write.
      get "/dav/addressbook/aiden.vcf"
      assert_equal updated, last_response.body
      assert_equal etag, last_response["ETag"]

      request "/dav/addressbook/", method: "PROPFIND", "HTTP_DEPTH" => "1", input: etag_only_propfind
      assert_includes last_response.body, "<d:getetag>#{etag}</d:getetag>"
    end
  end

  def test_put_with_a_stale_etag_is_refused_and_changes_nothing
    with_contacts({"aiden" => "Aiden"}) do
      get "/dav/addressbook/aiden.vcf"
      before = last_response.body

      put_request "aiden", card("aiden", "Aiden Smith"),
        "CONTENT_TYPE" => VCARD, "HTTP_IF_MATCH" => %("#{"0" * 64}")

      assert_equal 412, last_response.status

      get "/dav/addressbook/aiden.vcf"
      assert_equal before, last_response.body
    end
  end

  # If-Match on a resource that does not exist fails rather than creating
  # — the client named a representation it never saw (RFC 7232 section
  # 3.1).
  def test_put_with_if_match_against_nothing_is_refused
    with_contacts({}) do
      put_request "new", card("new", "New"),
        "CONTENT_TYPE" => VCARD, "HTTP_IF_MATCH" => %("#{"0" * 64}")

      assert_equal 412, last_response.status
    end
  end

  # RFC 7232 section 3.1 allows If-Match a list of tags, and `*` for any
  # current representation.
  def test_if_match_accepts_a_list_and_a_star
    with_contacts({"aiden" => "Aiden"}) do
      get "/dav/addressbook/aiden.vcf"
      etag = last_response["ETag"]
      updated = card("aiden", "Aiden Smith")

      put_request "aiden", updated, "CONTENT_TYPE" => VCARD,
        "HTTP_IF_MATCH" => %("#{"0" * 64}", #{etag})
      assert_equal 204, last_response.status

      put_request "aiden", card("aiden", "Aiden"), "CONTENT_TYPE" => VCARD, "HTTP_IF_MATCH" => "*"
      assert_equal 204, last_response.status
    end
  end

  def test_put_without_a_conditional_overwrites
    with_contacts({"aiden" => "Aiden"}) do
      put_request "aiden", card("aiden", "Aiden Smith"), "CONTENT_TYPE" => VCARD

      assert_equal 204, last_response.status

      get "/dav/addressbook/aiden.vcf"
      assert_includes last_response.body, "Aiden Smith"
    end
  end

  # RFC 6352 section 6.3.2.3: a strong ETag belongs on a PUT answer only
  # when what was stored is the submission octet for octet. A birthday is
  # subtracted before storage and composed back in on read, so a PUT that
  # carried one elsewhere in the card than where compose puts it must not
  # claim the tag — the client refetches instead. macOS writes BDAY
  # mid-card, which is the shape here.
  def test_a_put_whose_birthday_moves_goes_without_the_strong_etag
    born = card("new", "New").sub("FN:New\r\n", "FN:New\r\nBDAY:1985-04-12\r\n")

    with_contacts({}) do
      put_request "new", born, "CONTENT_TYPE" => VCARD, "HTTP_IF_NONE_MATCH" => "*"

      assert_equal 201, last_response.status
      assert_nil last_response["ETag"]

      # What the client refetches carries the birthday, composed before
      # the END, and that refetched tag is the one the next write matches.
      get "/dav/addressbook/new.vcf"
      assert_includes last_response.body, "BDAY:1985-04-12\r\nEND:VCARD"
      etag = last_response["ETag"]

      put_request "new", card("new", "New"), "CONTENT_TYPE" => VCARD, "HTTP_IF_MATCH" => etag
      assert_equal 204, last_response.status
    end
  end

  # The boundary of the same rule: a birthday already sitting where
  # compose puts it stores octet for octet, and the tag is honest.
  def test_a_put_whose_birthday_composes_in_place_keeps_the_strong_etag
    born = card("new", "New").sub("END:VCARD\r\n", "BDAY:1985-04-12\r\nEND:VCARD\r\n")

    with_contacts({}) do
      put_request "new", born, "CONTENT_TYPE" => VCARD, "HTTP_IF_NONE_MATCH" => "*"

      assert_equal 201, last_response.status
      assert_equal %("#{Digest::SHA256.hexdigest(born)}"), last_response["ETag"]
    end
  end

  # The same omission for the rewrite that carries a birthday across:
  # the stored card is the submission plus the BDAY line macOS dropped,
  # so the answer cannot claim the tag — the client refetches, and the
  # refetch is what shows the birthday survived its edit.
  def test_a_put_that_carries_a_birthday_back_goes_without_the_strong_etag
    unrendered = card("new", "New").sub("END:VCARD\r\n", "BDAY:1985-04\r\nEND:VCARD\r\n")

    with_contacts({}) do
      put_request "new", unrendered, "CONTENT_TYPE" => VCARD, "HTTP_IF_NONE_MATCH" => "*"

      edited = card("new", "New Smith")
      put_request "new", edited, "CONTENT_TYPE" => VCARD

      assert_equal 204, last_response.status
      assert_nil last_response["ETag"]

      get "/dav/addressbook/new.vcf"
      assert_includes last_response.body, "BDAY:1985-04\r\nEND:VCARD"
    end
  end

  # The preconditions of RFC 6352 section 6.3.2.1, marshalled as 412s
  # in the DAV:error form RFC 4918 section 16 defines.
  def test_put_of_a_non_vcard_media_type_names_its_precondition
    with_contacts({}) do
      put_request "new", card("new", "New"), "CONTENT_TYPE" => "text/plain"

      assert_equal 412, last_response.status
      assert_includes last_response.body, "<card:supported-address-data/>"
    end
  end

  def test_put_of_bytes_that_are_not_utf_8_names_its_precondition
    with_contacts({}) do
      put_request "new", "\xFF\xFE".b, "CONTENT_TYPE" => VCARD

      assert_equal 412, last_response.status
      assert_includes last_response.body, "<card:valid-address-data/>"
    end
  end

  def test_put_of_something_that_is_not_a_card_names_its_precondition
    with_contacts({}) do
      put_request "new", "not a vCard at all", "CONTENT_TYPE" => VCARD
      assert_equal 412, last_response.status

      # Lines that parse are still not a card without the envelope.
      put_request "new", "FN:Nope\r\n", "CONTENT_TYPE" => VCARD
      assert_equal 412, last_response.status

      assert_includes last_response.body, "<card:valid-address-data/>"
    end
  end

  # A line that will not read is not grounds for refusing the card —
  # RFC 6352 section 6.3.2.2 has the server keep what it does not
  # understand — so the PUT succeeds and the bytes go back out whole.
  def test_put_of_a_card_with_a_line_that_will_not_read_is_accepted_whole
    unreadable = card("new", "New").sub("FN:New\r\n", "FN:New\r\nTEL;HOME:+1-555-1234\r\n")

    with_contacts({}) do
      put_request "new", unreadable, "CONTENT_TYPE" => VCARD

      assert_equal 201, last_response.status

      get "/dav/addressbook/new.vcf"

      assert_equal unreadable, last_response.body
    end
  end

  # The one report left in the app: a card that breaks an assumption
  # about what macOS Contacts sends is news that the assumption is
  # wrong, and an arrival is the event worth a message — a read happens
  # on every page load. A bare CR packs two content lines into one
  # line's bytes, which is the assumption this card breaks.
  def test_put_of_a_card_breaking_a_parser_assumption_is_reported
    packed = card("new", "New").sub("FN:New\r\n", "FN:New\rNOTE:b\r\n")

    with_contacts({}) do
      messages = capturing_sentry {
        put_request "new", packed, "CONTENT_TYPE" => VCARD
      }

      assert_equal 201, last_response.status
      assert_equal 1, messages.length
      assert_match "broke 1 parser assumption", messages.fetch(0)
    end
  end

  # Nothing else reports: an ordinary card arrives in silence.
  def test_put_of_an_ordinary_card_is_quiet
    with_contacts({}) do
      messages = capturing_sentry {
        put_request "new", card("new", "New"), "CONTENT_TYPE" => VCARD
      }

      assert_equal 201, last_response.status
      assert_empty messages
    end
  end

  def test_put_of_a_card_whose_uid_belongs_to_another_card
    with_contacts({"aiden" => "Aiden"}) do
      put_request "znorth", card("aiden", "Aiden"), "CONTENT_TYPE" => VCARD

      assert_equal 412, last_response.status
      assert_includes last_response.body, "<card:no-uid-conflict>"
      # Where the UID already lives, which RFC 6352 section 6.3.2.1 asks
      # the error to say.
      assert_includes last_response.body, "<d:href>/dav/addressbook/aiden.vcf</d:href>"
    end
  end

  # The id is the card's UID here, so a card whose UID names nothing at
  # all is still a conflict: the href it was PUT to would not be the
  # href it answers at.
  def test_put_of_a_card_whose_uid_is_not_its_href
    with_contacts({}) do
      put_request "new", card("other", "New"), "CONTENT_TYPE" => VCARD

      assert_equal 412, last_response.status
      assert_includes last_response.body, "<card:no-uid-conflict/>"
      refute_includes last_response.body, "d:href"
    end
  end

  def test_put_of_a_card_with_no_uid
    with_contacts({}) do
      card = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:New\r\nEND:VCARD\r\n"
      put_request "new", card, "CONTENT_TYPE" => VCARD

      assert_equal 412, last_response.status
      assert_includes last_response.body, "<card:no-uid-conflict/>"
    end
  end

  # RFC 6352 section 6.3.2.2: what the server does not model survives
  # the trip, because the submitted bytes are the stored bytes.
  def test_put_stores_what_it_was_sent_verbatim
    card = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:New\r\nX-APPLE-FOO:kept\r\nUID:new\r\nEND:VCARD\r\n"

    with_contacts({}) do
      put_request "new", card, "CONTENT_TYPE" => VCARD

      get "/dav/addressbook/new.vcf"
      assert_equal card, last_response.body
    end
  end

  # A body arrives flagged ASCII-8BIT — Rack's rule for request input —
  # and becomes UTF-8 where the route meets the wire, so a card with
  # non-ASCII in it stores and serves as the UTF-8 it is.
  def test_put_of_a_binary_flagged_body_stores_as_utf_8
    card = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden Åberg\r\nUID:new\r\nEND:VCARD\r\n"

    with_contacts({}) do
      put_request "new", card.dup.force_encoding(Encoding::BINARY),
        "CONTENT_TYPE" => VCARD, "HTTP_IF_NONE_MATCH" => "*"

      assert_equal 201, last_response.status

      get "/dav/addressbook/new.vcf"
      assert_equal Encoding::UTF_8, last_response.body.encoding
      assert_equal card, last_response.body
    end
  end

  # A last segment that is not the <id>.vcf shape can address no
  # resource here, created or read — the 404 the GET handler gives it.
  def test_put_to_a_uri_that_cannot_address_a_card
    with_contacts({}) do
      request "/dav/addressbook/bad.id.vcf",
        method: "PUT", input: card("bad.id", "Bad"), "CONTENT_TYPE" => VCARD

      assert_equal 404, last_response.status
    end
  end

  # A card as Contacts would send one, so the routes are exercised
  # against stored bytes rather than anything this test renders.
  def card(id, name)
    "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:#{name}\r\nUID:#{id}\r\nEND:VCARD\r\n"
  end

  # Hands the app a throwaway store so the multi-contact routes can be
  # exercised without touching the exchange fixture data, and yields it
  # so a test can change a card mid-request-sequence. Only the store is
  # swapped: nothing in a request reads configuration.
  def with_contacts(names)
    Dir.mktmpdir do |dir|
      original = ProTacts::Web.store

      ProTacts::Store.connect(Pathname.new(dir) / "contacts.db") do |store|
        ProTacts::Web.store = store
        names.each do |id, name|
          store.put(id, card(id, name))
        end
        yield store
      ensure
        ProTacts::Web.store = original
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

  def test_listing_and_multiget_serve_every_stored_contact
    with_contacts({"aiden" => "Aiden", "znorth" => "Zed"}) do
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
    with_contacts({"aiden" => "Aiden"}) do
      request "/dav/addressbook/", method: "REPORT", input: multiget("aiden", "nope")

      assert_equal 207, last_response.status
      assert_includes last_response.body, "FN:Aiden"
      assert_includes last_response.body, "/dav/addressbook/nope.vcf"
      assert_includes last_response.body, "HTTP/1.1 404 Not Found"
    end
  end

  def test_multiget_escapes_vcard_content_for_xml
    with_contacts({"aiden" => "A & B <Team>"}) do
      request "/dav/addressbook/", method: "REPORT", input: multiget("aiden")

      assert_equal 207, last_response.status
      assert_includes last_response.body, "FN:A &amp; B &lt;Team&gt;"
    end
  end

  def test_sync_collection_returns_etags_only
    with_contacts({"aiden" => "Aiden"}) do
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

    with_contacts({"aiden" => "Aiden"}) do
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
    with_contacts({"aiden" => "Aiden"}) do
      request "/dav/addressbook/", method: "PROPFIND", "HTTP_DEPTH" => "1", input: etag_only_propfind
      etag = last_response.body[%r{<d:getetag>(.+)</d:getetag>}, 1]

      get "/dav/addressbook/aiden.vcf"
      assert_equal etag, last_response["ETag"]

      request "/dav/addressbook/", method: "REPORT", input: multiget("aiden")
      assert_includes last_response.body, "<d:getetag>#{etag}</d:getetag>"
    end
  end

  def test_a_changed_card_changes_its_etag_and_the_collection_tags
    with_contacts({"aiden" => "Aiden"}) do |store|
      read_tags = lambda {
        request "/dav/addressbook/", method: "PROPFIND"
        [last_response.body[%r{<d:getetag>(.+)</d:getetag>}, 1],
         last_response.body[%r{<cs:getctag>(.+)</cs:getctag>}, 1],
         last_response.body[%r{<d:sync-token>(.+)</d:sync-token>}, 1]]
      }

      before = read_tags.call
      assert_equal before, read_tags.call # stable across requests

      store.put("aiden", card("aiden", "Aiden Smith"))
      after = read_tags.call

      before.zip(after).each { refute_equal it.first, it.last }
    end
  end
end
