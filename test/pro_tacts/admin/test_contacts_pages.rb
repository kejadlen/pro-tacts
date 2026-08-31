require_relative "../../test_helper"

require "pathname"
require "rack/test"
require "tmpdir"

require "pro_tacts/store"
require "pro_tacts/web"

# The read-only admin UI (docs/DESIGN.md), exercised the same way
# WebTest exercises the CardDAV routes: real requests through the Roda
# app, against a throwaway store.
class AdminContactsPagesTest < Minitest::Test
  include Rack::Test::Methods

  def app
    ProTacts::Web
  end

  def setup
    header "Tailscale-User-Login", "test@example.com"
  end

  ADA = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Ada Lovelace\r\nN:Lovelace;Ada;;;\r\n" \
    "TEL;TYPE=mobile:+1-555-0100\r\nEMAIL;TYPE=home:ada@example.com\r\n" \
    "ADR;TYPE=home:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n" \
    "BDAY:1985-12-10\r\nNOTE:Countess of Lovelace.\r\nUID:ada\r\nEND:VCARD\r\n"

  def with_contacts(cards)
    Dir.mktmpdir do |dir|
      original = ProTacts::Web.store

      ProTacts::Store.connect(Pathname.new(dir) / "contacts.db") do |store|
        ProTacts::Web.store = store
        cards.each { |id, card| store.put(id, card) }
        yield store
      ensure
        ProTacts::Web.store = original
      end
    end
  end

  def test_index_lists_recently_updated_contacts
    with_contacts({"ada" => ADA}) do
      get "/admin/contacts"

      assert_equal 200, last_response.status
      assert_equal "text/html; charset=utf-8", last_response["Content-Type"]
      assert_includes last_response.body, "Ada Lovelace"
      assert_includes last_response.body, "recently updated"
    end
  end

  def test_index_with_no_contacts_says_so
    with_contacts({}) { get "/admin/contacts" }

    assert_includes last_response.body, "No contacts yet."
  end

  def test_search_narrows_to_matches_across_contacts
    grace = ADA.sub("Ada Lovelace", "Grace Hopper")
      .sub("ada@example.com", "grace@example.com")
      .sub("UID:ada", "UID:grace")

    with_contacts({"ada" => ADA, "grace" => grace}) do
      get "/admin/contacts", q: "hopper"

      assert_includes last_response.body, "Grace Hopper"
      refute_includes last_response.body, "Ada Lovelace"
      assert_includes last_response.body, "results"
    end
  end

  # Match generously (docs/DESIGN.md): a contact is findable by name,
  # any of its values, or the groups it belongs to.
  def test_search_matches_a_phone_or_email_value
    with_contacts({"ada" => ADA}) do
      get "/admin/contacts", q: "555-0100"
      assert_includes last_response.body, "Ada Lovelace"

      get "/admin/contacts", q: "ada@example.com"
      assert_includes last_response.body, "Ada Lovelace"
    end
  end

  def test_search_with_no_matches_says_so
    with_contacts({"ada" => ADA}) do
      get "/admin/contacts", q: "nobody"

      assert_includes last_response.body, "No contacts match."
    end
  end

  def test_show_renders_the_contacts_fields
    with_contacts({"ada" => ADA}) do
      get "/admin/contacts/ada"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "Ada Lovelace"
      assert_includes last_response.body, "mobile"
      assert_includes last_response.body, "+1-555-0100"
      assert_includes last_response.body, "12 Analytical Way"
      assert_includes last_response.body, "London"
      assert_includes last_response.body, "December 10, 1985"
      assert_includes last_response.body, "Countess of Lovelace."
    end
  end

  # Empty attributes do not render (docs/DESIGN.md) — a bare card shows
  # only the header, not a scaffold of blank rows.
  def test_show_hides_attributes_the_contact_has_no_data_for
    bare = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Bare Contact\r\nUID:bare\r\nEND:VCARD\r\n"

    with_contacts({"bare" => bare}) do
      get "/admin/contacts/bare"

      assert_equal 200, last_response.status
      refute_includes last_response.body, "notes"
      refute_includes last_response.body, "birthday"
    end
  end

  def test_show_of_an_unknown_contact_is_404
    with_contacts({}) { get "/admin/contacts/nope" }

    assert_equal 404, last_response.status
  end
end
