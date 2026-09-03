require_relative "../../test_helper"

require "date"
require "pathname"
require "rack/test"
require "tmpdir"

require "pro_tacts/store"
require "pro_tacts/web"

# The dashboard root (docs/DESIGN.md), exercised the same way WebTest
# exercises the CardDAV routes: real requests through the Roda app,
# against a throwaway store. The birthdays column reads the real
# clock, so its cards are built around Date.today rather than a fixed
# date.
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
      get "/"

      assert_equal 200, last_response.status
      assert_equal "text/html; charset=utf-8", last_response["Content-Type"]
      assert_includes last_response.body, "Ada Lovelace"
      assert_includes last_response.body, "recently updated"
    end
  end

  def test_index_with_no_contacts_says_so
    with_contacts({}) { get "/" }

    assert_includes last_response.body, "No contacts yet."
  end

  # A contact born on `date`'s month and day in 2000, so the
  # birthdays column's ordering and labels are deterministic against
  # the real clock.
  def born(date, name:, id:)
    "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:#{name}\r\n" \
      "BDAY:2000-%02d-%02d\r\nUID:#{id}\r\nEND:VCARD\r\n" % [date.month, date.day]
  end

  # The ambient column answers "who is next": names in arrival order,
  # each row opening the contact's card, the birthday shown with the
  # age it turns and the day counted down beside it.
  def test_index_lists_birthdays_in_arrival_order_linking_to_the_contact
    tomorrow = born(Date.today + 1, name: "Sooner Person", id: "sooner")
    fortnight = born(Date.today + 13, name: "Later Person", id: "later")

    with_contacts({"later" => fortnight, "sooner" => tomorrow}) do
      get "/"

      body = last_response.body
      assert_includes body, "upcoming birthdays"
      # Both contacts also sit in "recently updated", where a
      # same-millisecond tie can order them either way — arrival
      # order is asserted inside the birthdays column alone.
      birthdays = body.split("upcoming birthdays").last
      assert birthdays.index("Sooner Person") < birthdays.index("Later Person")
      # The rows are CardRows — li under ul.card, where the row look
      # lives — not bare anchors.
      assert_includes body, '<li><a href="/contacts/sooner">'
      assert_includes body, "(turns #{(Date.today + 1).year - 2000})"
      assert_includes body, "tomorrow"
      assert_includes body, "in 13d"
    end
  end

  # A birthday without a year is on the day — shown with no age, the
  # one thing a missing year cannot answer.
  def test_index_shows_a_birthday_without_a_year_with_no_age
    week = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:No Year\r\n" \
      "BDAY;X-APPLE-OMIT-YEAR=1604:1604-%02d-%02d\r\nUID:noyear\r\nEND:VCARD\r\n" %
      [(Date.today + 7).month, (Date.today + 7).day]

    with_contacts({"noyear" => week}) do
      get "/"

      body = last_response.body
      assert_includes body, "No Year"
      assert_includes body, "in 7d"
      refute_includes body, "turns"
    end
  end

  def test_index_with_no_birthdays_says_so
    with_contacts({}) { get "/" }

    assert_includes last_response.body, "No birthdays to show."
  end

  # Searching narrows the contacts column; the ambient column stays
  # where it is, still answering its own question.
  def test_search_leaves_the_birthdays_column_standing
    birthday = born(Date.today + 3, name: "Birthday Person", id: "birthday")

    with_contacts({"ada" => ADA, "birthday" => birthday}) do
      get "/", q: "hopper"

      assert_includes last_response.body, "No contacts match."
      assert_includes last_response.body, "Birthday Person"
    end
  end

  def test_search_narrows_to_matches_across_contacts
    grace = ADA.sub("Ada Lovelace", "Grace Hopper")
      .sub("ada@example.com", "grace@example.com")
      .sub("UID:ada", "UID:grace")

    with_contacts({"ada" => ADA, "grace" => grace}) do
      get "/", q: "hopper"

      # The columns split on the birthdays column's label: matching
      # narrows the contacts column, and Ada stays out of it — she is
      # still beside it, in the ambient column where she belongs.
      contacts_column = last_response.body.split("upcoming birthdays").first
      assert_includes contacts_column, "Grace Hopper"
      refute_includes contacts_column, "Ada Lovelace"
      assert_includes last_response.body, "results"
    end
  end

  # Match generously (docs/DESIGN.md): a contact is findable by name,
  # any of its values, or the groups it belongs to.
  def test_search_matches_a_phone_or_email_value
    with_contacts({"ada" => ADA}) do
      get "/", q: "555-0100"
      assert_includes last_response.body, "Ada Lovelace"

      get "/", q: "ada@example.com"
      assert_includes last_response.body, "Ada Lovelace"
    end
  end

  def test_search_with_no_matches_says_so
    with_contacts({"ada" => ADA}) do
      get "/", q: "nobody"

      assert_includes last_response.body, "No contacts match."
    end
  end

  def test_show_renders_the_contacts_fields
    with_contacts({"ada" => ADA}) do
      get "/contacts/ada"

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

  # A value with no TYPE parameter still gets a key — the fallback
  # names the kind of value, so every row in the grid is labeled.
  def test_show_labels_untyped_values_with_the_property_name
    untyped = ADA.sub("TEL;TYPE=mobile:", "TEL:").sub("EMAIL;TYPE=home:", "EMAIL:")

    with_contacts({"ada" => untyped}) do
      get "/contacts/ada"

      assert_includes last_response.body, '<dt class="type-label">phone</dt>'
      assert_includes last_response.body, '<dt class="type-label">email</dt>'
    end
  end

  # Empty attributes do not render (docs/DESIGN.md) — a bare card shows
  # only the header, not a scaffold of blank rows.
  def test_show_hides_attributes_the_contact_has_no_data_for
    bare = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Bare Contact\r\nUID:bare\r\nEND:VCARD\r\n"

    with_contacts({"bare" => bare}) do
      get "/contacts/bare"

      assert_equal 200, last_response.status
      refute_includes last_response.body, '<dt class="type-label">notes</dt>'
      refute_includes last_response.body, '<dt class="type-label">birthday</dt>'
    end
  end

  # Empty values are absent by the time the view reads them (see
  # Contact), so a present-but-empty property renders no row either.
  def test_show_hides_attributes_whose_values_are_empty
    empty = ADA.sub("TEL;TYPE=mobile:+1-555-0100", "TEL;TYPE=mobile:")
      .sub("NOTE:Countess of Lovelace.", "NOTE:")

    with_contacts({"ada" => empty}) do
      get "/contacts/ada"

      refute_includes last_response.body, '<dt class="type-label">phone</dt>'
      refute_includes last_response.body, "notes"
    end
  end

  # No properties at all means no grid, not an empty one — an empty
  # <dl> would still eat the gap card-body puts before it, leaving the
  # name pinned near the top of the card instead of centered in it.
  def test_show_of_a_bare_contact_renders_no_grid
    bare = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Bare Contact\r\nUID:bare\r\nEND:VCARD\r\n"

    with_contacts({"bare" => bare}) do
      get "/contacts/bare"

      refute_includes last_response.body, "detail-grid"
    end
  end

  def test_show_of_an_unknown_contact_is_404
    with_contacts({}) { get "/contacts/nope" }

    assert_equal 404, last_response.status
  end
end
