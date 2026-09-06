require_relative "../../test_helper"
require_relative "../../photo_card"

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

  # A card with a NICKNAME lists as "Nickname (Name)" — the name
  # someone is known by, the formal one kept beside it. The plain-name
  # row is what every other index test already shows.
  def test_index_lists_a_nicknamed_contact_as_nickname_and_name
    red = ADA.sub("FN:Ada Lovelace", "FN:Sarah\r\nNICKNAME:Red").sub("UID:ada", "UID:red")

    with_contacts({"red" => red}) do
      get "/"

      assert_includes last_response.body, "Red (Sarah)"
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

  # The search lives in the page header (docs/DESIGN.md), rendered by
  # the layout on every screen now — not just the dashboard's — so
  # the header's height never changes between pages and finding a
  # contact never requires going home first. This pins the wiring,
  # not just the behavior: a screen that forgets `autofocus` loses
  # the focused-and-ready entry point with no route failing.
  def test_the_search_lives_in_the_header
    with_contacts({"ada" => ADA}) do
      get "/"
      header = last_response.body.split("<main").first
      assert_includes header, "search-form"
      assert_includes header, "name=\"q\""
      assert_includes header, "autofocus"

      get "/", q: "ada"
      header = last_response.body.split("<main").first
      assert_includes header, "value=\"ada\""
      refute_includes header, "autofocus"
    end
  end

  # The same chrome on a record's own page: the search rides the
  # header there too, empty and unfocused — the record is that
  # page's content, not a query.
  def test_the_search_renders_on_detail_pages_too
    with_contacts({"ada" => ADA}) do
      get "/contacts/ada"

      header = last_response.body.split("<main").first
      assert_includes header, "search-form"
      # No value attribute at all — the record's page carries no
      # query, and Phlex omits the attribute for nil rather than
      # rendering it empty.
      assert_includes header, '<input type="search" name="q" placeholder="Search contacts">'
      refute_includes header, "autofocus"
    end
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

  # The nickname is a name the contact lists under, so it finds the
  # contact the same way the name does.
  def test_search_matches_the_nickname
    red = ADA.sub("FN:Ada Lovelace", "FN:Sarah\r\nNICKNAME:Red").sub("UID:ada", "UID:red")

    with_contacts({"red" => red}) do
      get "/", q: "red"

      assert_includes last_response.body, "Red (Sarah)"
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
      refute_includes last_response.body, '<dt class="type-label">nickname</dt>'
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

  # The stored bytes are the truth the grid interprets, so the exact
  # bytes stay reachable in their own card under the record —
  # collapsed by default, so a PHOTO-heavy card does not push the page
  # around. The stored card is the assertion's source of truth, not
  # the input: a write composes the modeled BDAY back in, so what is
  # served can be ordered differently from what was put.
  def test_show_offers_the_raw_card_collapsed
    with_contacts({"ada" => ADA}) do |store|
      get "/contacts/ada"

      body = last_response.body
      assert_includes body, '<details><summary class="type-label">raw vCard</summary>'
      assert_includes body, store.contact("ada").vcard.to_s
      refute_includes body, "<details open"
    end
  end

  # A photo card's raw section elides the base64 wall to its octet
  # count; the property's name and parameters, and every other line,
  # stay byte for byte. The refuted chunk is a continuation line of
  # the stored card itself — the one string guaranteed contiguous in
  # an unelided render.
  def test_show_elides_photo_payloads_in_the_raw_card
    with_contacts({"pic" => PhotoCard.photo("pic", bytes: 256)}) do |store|
      get "/contacts/pic"

      body = last_response.body
      assert_includes body, " octets elided]"
      chunk = store.contact("pic").vcard.to_s.lines.grep(/\A /).first
      refute_includes body, chunk
      assert_includes body, "X-IMAGETYPE:PHOTO"
    end
  end

  # A memoji's parameter section is itself 1,685 octets of base64 on
  # one line — a long parameter value elides like a long property
  # value, and the short parameters around it render whole.
  def test_show_elides_long_parameter_values_in_the_raw_card
    with_contacts({"mochi" => PhotoCard.memoji("mochi")}) do |store|
      get "/contacts/mochi"

      body = last_response.body
      assert_includes body, "VND-63-MEMOJI-DETAILS=["
      assert_includes body, ";ENCODING=b;TYPE=JPEG:["
      details = store.contact("mochi").properties
        .find { it.name.casecmp?("PHOTO") }.parameters
        .find { |name, _| name.casecmp?("VND-63-MEMOJI-DETAILS") }.last
      refute_includes body, details[0, 60]
    end
  end

  # Any overly long value elides, not only a picture's: a long NOTE
  # renders as its count in the raw card while the grid above still
  # shows the text itself.
  def test_show_elides_any_overly_long_value
    note = "n" * 200
    card = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Wordy\r\nNOTE:#{note}\r\nUID:wordy\r\nEND:VCARD\r\n"

    with_contacts({"wordy" => card}) do
      get "/contacts/wordy"

      assert_includes last_response.body, "NOTE:[#{note.bytesize} octets elided]"
    end
  end

  # A card that will not parse is served from its bytes regardless —
  # the raw section is the one thing such a card has to show, so it
  # renders with no grid under the header, not instead of the page.
  def test_show_of_a_bare_contact_renders_no_grid
    bare = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Bare Contact\r\nUID:bare\r\nEND:VCARD\r\n"

    with_contacts({"bare" => bare}) do
      get "/contacts/bare"

      refute_includes last_response.body, "detail-grid"
      assert_includes last_response.body, "<details"
    end
  end

  # The nickname is a name-like fact, so it rides under the name in
  # the header, in the heading family but muted — a name, visibly
  # secondary to the formal one — and the grid keeps only what
  # reaches the person.
  def test_show_puts_the_nickname_under_the_name_in_the_header
    red = ADA.sub("FN:Ada Lovelace", "FN:Sarah\r\nNICKNAME:Red").sub("UID:ada", "UID:red")

    with_contacts({"red" => red}) do
      get "/contacts/red"

      body = last_response.body
      header = body.split("<dl").first
      assert_includes header, "Sarah</h1>"
      assert_includes header, 'class="type-h3 gl-muted"'
      assert_includes header, ">Red<"
      refute_includes body, '">nickname</dt>'
    end
  end

  def test_show_of_an_unknown_contact_is_404
    with_contacts({}) { get "/contacts/nope" }

    assert_equal 404, last_response.status
  end

  ## Photos

  # No picture, no avatar: an initials circle beside the name in
  # type-h2 would repeat what the name already says, so a contact
  # without a photo renders the header as the name alone.
  def test_show_without_a_picture_renders_no_avatar
    with_contacts({"ada" => ADA}) do
      get "/contacts/ada"

      assert_equal 200, last_response.status
      refute_includes last_response.body, 'class="avatar"'
    end
  end

  # A contact with a picture renders it where the initials were —
  # here the detail header's large avatar — pointing at the photo
  # route rather than carrying the bytes in the page. Alt is empty:
  # the name is the heading right beside it.
  def test_show_renders_the_cards_picture_as_the_avatar
    with_contacts({"pic" => PhotoCard.photo("pic", bytes: 256)}) do
      get "/contacts/pic"

      assert_equal 200, last_response.status
      assert_includes last_response.body, '<img class="avatar" src="/contacts/pic/photo" alt=""'
      assert_includes last_response.body, 'data-size="xl"'
      refute_includes last_response.body, '<span class="avatar"'
    end
  end

  # The dashboard rows render the same avatar — one component, every
  # slot — so a picture shows in recently updated and in results.
  def test_the_index_rows_render_the_picture_too
    with_contacts({"pic" => PhotoCard.photo("pic", bytes: 256)}) do
      get "/"

      assert_includes last_response.body, 'src="/contacts/pic/photo"'

      get "/", q: "no-match-for-this"
      refute_includes last_response.body, 'src="/contacts/pic/photo"'
    end
  end

  # The route the avatars point at: the decoded bytes under the type
  # their own magic bytes name, with the contact's etag — so a picture
  # changes exactly when its card does.
  def test_the_photo_route_serves_the_decoded_bytes
    with_contacts({"pic" => PhotoCard.photo("pic", bytes: 256)}) do |store|
      get "/contacts/pic/photo"

      assert_equal 200, last_response.status
      assert_equal "image/jpeg", last_response["Content-Type"]
      assert_equal store.contact("pic").photo.bytes, last_response.body
      assert_equal store.contact("pic").etag, last_response["ETag"]
    end
  end

  # A contact whose card carries no picture a browser can show is no
  # match at the route — the views never point at one — same 404 as an
  # unknown contact.
  def test_the_photo_route_is_404_without_a_picture
    with_contacts({"ada" => ADA}) do
      get "/contacts/ada/photo"
      assert_equal 404, last_response.status

      get "/contacts/nobody/photo"
      assert_equal 404, last_response.status
    end
  end

  # The seed book carries one fixture card per picture kind macOS
  # sends — photo, emoji, memoji, monogram, promoted from real client
  # sessions (see test/fixtures/cards and docs/macos-contacts.md) —
  # and these tests are what keeps them exercising the path: a seed
  # that stops parsing, or stops sniffing to an image, fails here
  # rather than passing silently as an initials avatar. Runs against
  # the suite's fixture store rather than a with_contacts throwaway,
  # because the seeds themselves are the thing under test.
  %w[photo emoji memoji monogram].each do |id|
    define_method("test_the_#{id}_seed_serves_its_picture") do
      get "/contacts/#{id}"
      assert_equal 200, last_response.status
      assert_includes last_response.body, "src=\"/contacts/#{id}/photo\""

      get "/contacts/#{id}/photo"
      assert_equal 200, last_response.status
      assert_equal "image/jpeg", last_response["Content-Type"]
    end
  end

  ## Creating contacts

  # The add affordance and the dialog it opens, both carried by the
  # dashboard: a popovertarget button and a popover element, the
  # Popover API's declarative pair (see Admin::ContactDialog).
  # rack-test cannot open a popover, so this pins the wiring the same
  # way the search-in-the-header test does — the attributes a browser
  # acts on, asserted on the page a browser gets.
  def test_the_dashboard_carries_the_new_contact_dialog
    with_contacts({}) do
      get "/"

      body = last_response.body
      assert_includes body, '<button data-size="sm" popovertarget="new-contact">add contact</button>'
      assert_includes body, '<dialog id="new-contact" popover="auto">'
      assert_includes body, '<form id="new-contact-form" action="/contacts" method="post">'
      # The captions render — a bare string mid-block is void in
      # Phlex, so the labels carry their text through plain (the
      # assertion keeps a regression from rendering a silent label).
      assert_includes body, '<label class="field">First<input type="text" name="first" required autofocus></label>'
      assert_includes body, '<label class="field">Last<input type="text" name="last"></label>'
      assert_includes body, 'popovertargetaction="hide"'
    end
  end

  # A create lands through Store#put — change log, index, and all —
  # and the answer is a redirect to the record, the details page
  # where further editing belongs.
  def test_creating_a_contact_from_the_dialog
    with_contacts({}) do |store|
      post "/contacts", first: "Grace", last: "Hopper"

      assert_equal 303, last_response.status
      id = last_response["Location"].delete_prefix("/contacts/")
      assert_match(/\A[\w-]+\z/, id)

      follow_redirect!
      assert_equal 200, last_response.status
      assert_includes last_response.body, "Grace Hopper"

      # N and FN both written, per RFC 2426 section 4's mandatory set,
      # and the card's UID is the id it is served under.
      card = store.contact(id).vcard.to_s
      assert_includes card, "N:Hopper;Grace;;;"
      assert_includes card, "FN:Grace Hopper"
      assert_includes card, "UID:#{id}"
      assert(store.changes.any? { it.action == "put" && it.card_id == id })
    end
  end

  # A single name is a fine contact: the model carries either half
  # alone, and the card says exactly what was given.
  def test_creating_a_contact_with_only_a_first_name
    with_contacts({}) do |store|
      post "/contacts", first: "Cher"

      assert_equal 303, last_response.status
      id = last_response["Location"].delete_prefix("/contacts/")
      card = store.contact(id).vcard.to_s
      assert_includes card, "N:;Cher;;;"
      assert_includes card, "FN:Cher"
    end
  end

  # A name is text, and the card is structure: a comma or semicolon
  # in a name must not read as a component separator (RFC 2426
  # section 2.4.2).
  def test_names_with_punctuation_are_escaped_in_the_card
    with_contacts({}) do |store|
      post "/contacts", first: "Ada, Jr.", last: "Lovelace; Countess"

      assert_equal 303, last_response.status
      id = last_response["Location"].delete_prefix("/contacts/")
      card = store.contact(id).vcard.to_s
      assert_includes card, "N:Lovelace\\; Countess;Ada\\, Jr.;;;"
      assert_includes card, "FN:Ada\\, Jr. Lovelace\\; Countess"
    end
  end

  # The backstop for the one request no browser can send (the first
  # field is required): a plain dashboard re-render with the refusal
  # in a toast, and nothing stored.
  def test_a_nameless_create_is_refused_with_a_toast
    with_contacts({}) do |store|
      post "/contacts", first: " ", last: ""

      assert_equal 200, last_response.status
      assert_includes last_response.body, '<div role="status" data-fixed><span>A contact needs a name.</span></div>'
      assert_empty store.contacts
    end
  end

  ## Editing contacts

  # The edit screen: one form prefilled from the card — N's two
  # leading components as the name fields, the accessors' unescaped
  # readings as the rest — carrying the etag of the card it renders
  # from, the snapshot guard's hidden half.
  def test_the_edit_screen_prefills_the_cards_values
    red = ADA.sub("FN:Ada Lovelace", "FN:Sarah\r\nNICKNAME:Red").sub("UID:ada", "UID:red")

    with_contacts({"red" => red}) do |store|
      get "/contacts/red/edit"

      assert_equal 200, last_response.status
      body = last_response.body
      assert_includes body, '<form action="/contacts/red" method="post" class="field-stack">'
      assert_includes body, '<input type="text" name="first" value="Ada" required autofocus>'
      assert_includes body, '<input type="text" name="last" value="Lovelace">'
      assert_includes body, '<input type="text" name="nickname" value="Red">'
      assert_includes body, "<textarea name=\"note\" rows=\"4\">Countess of Lovelace.</textarea>"
      # The etag carries its quotes, HTML-escaped in the attribute.
      assert_includes body, %(<input type="hidden" name="etag" value="&quot;#{store.contact("red").etag.delete('"')}&quot;">)
    end
  end

  def test_the_edit_screen_of_an_unknown_contact_is_404
    with_contacts({}) { get "/contacts/nope/edit" }

    assert_equal 404, last_response.status
  end

  # The details page names its other mode: the edit link rides the
  # back-link's line at the right edge, so the card below stays a
  # clean read of the record.
  def test_the_details_page_links_to_the_edit_screen
    with_contacts({"ada" => ADA}) do
      get "/contacts/ada"

      assert_includes last_response.body,
        '<div class="record-nav"><a href="/" class="type-label">‹ contacts</a>' \
        '<a href="/contacts/ada/edit" class="btn" data-size="sm">edit</a></div>'
    end
  end

  # The save is addressed operations, and this is the whole design:
  # the four properties the form names are replaced, every other line
  # of the stored card is byte-identical, and the write lands through
  # Store#rewrite with its change-log entry.
  def test_saving_the_edit_replaces_only_the_addressed_properties
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "King", nickname: "Countess",
                               note: "First programmer.", etag: store.contact("ada").etag

      assert_equal 303, last_response.status
      assert_equal "/contacts/ada", last_response["Location"]

      card = store.contact("ada").vcard.to_s
      assert_includes card, "N:King;Ada;;;"
      assert_includes card, "FN:Ada King"
      assert_includes card, "NICKNAME:Countess"
      assert_includes card, "NOTE:First programmer."
      assert_includes card, "TEL;TYPE=mobile:+1-555-0100\r\n"
      assert_includes card, "EMAIL;TYPE=home:ada@example.com\r\n"
      assert_includes card, "ADR;TYPE=home:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n"
      assert_includes card, "UID:ada\r\n"
      # The birthday is model state the edit never touched, composed
      # back into the served card.
      assert_includes card, "BDAY:1985-12-10\r\n"
      assert(store.changes.any? { it.action == "edit" && it.card_id == "ada" })
    end
  end

  # Blank equals absent on the way back: a blank nickname or note
  # removes the property, as a blank value is absent to the reader
  # (Contact#text_of) — and filling one in adds it where the card
  # carried none.
  def test_a_blank_nickname_or_note_removes_the_property
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", nickname: "", note: "", etag: store.contact("ada").etag

      assert_equal 303, last_response.status
      card = store.contact("ada").vcard.to_s
      refute_includes card, "NICKNAME"
      refute_includes card, "NOTE"
    end
  end

  # N's unedited components — additional, prefixes, suffixes — splice
  # through byte for byte, the still-escaped value never rounding
  # through unescape and re-escape. The escaped semicolon inside the
  # additional component is the one an unescaped split would break on;
  # the seed's four components leave the fifth to the padding rule.
  def test_the_names_unedited_components_are_preserved_byte_for_byte
    honorific = ADA.sub("N:Lovelace;Ada;;;", "N:Lovelace;Ada;Byron\\; Countess;Countess of Lovelace")

    with_contacts({"ada" => honorific}) do |store|
      post "/contacts/ada", first: "Ada", last: "King", etag: store.contact("ada").etag

      assert_equal 303, last_response.status
      assert_includes store.contact("ada").vcard.to_s,
        "N:King;Ada;Byron\\; Countess;Countess of Lovelace;\r\n"
    end
  end

  # A card whose N stops short of five components is padded with the
  # same empties a whole-N writer would leave.
  def test_a_short_n_is_padded_to_five_components
    short = ADA.sub("N:Lovelace;Ada;;;", "N:Lovelace;Ada")

    with_contacts({"ada" => short}) do |store|
      post "/contacts/ada", first: "Ada", last: "King", etag: store.contact("ada").etag

      assert_equal 303, last_response.status
      assert_includes store.contact("ada").vcard.to_s, "N:King;Ada;;;\r\n"
    end
  end

  # Values are text and the card is structure: punctuation escapes in
  # the written lines, and a note's line breaks travel as the escape
  # rather than ending the property's line.
  def test_punctuation_and_line_breaks_escape_in_the_written_lines
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "King",
                               nickname: "Countess, of mathematics", note: "line one\nline two",
                               etag: store.contact("ada").etag

      assert_equal 303, last_response.status
      card = store.contact("ada").vcard.to_s
      assert_includes card, "NICKNAME:Countess\\, of mathematics\r\n"
      assert_includes card, "NOTE:line one\\nline two\r\n"

      follow_redirect!
      assert_includes last_response.body, "Countess, of mathematics"
    end
  end

  # A fold on a line the save never mentioned is the byte-identity
  # claim at its sharpest: the continuation survives with its own
  # bytes, not normalized into the unfolded reading.
  def test_a_folded_line_the_save_never_mentioned_is_left_alone
    folded = ADA.sub("TEL;TYPE=mobile:+1-555-0100\r\n", "TEL;TYPE=mobile:+1-555-\r\n 0100\r\n")

    with_contacts({"ada" => folded}) do |store|
      post "/contacts/ada", first: "Ada", last: "King", etag: store.contact("ada").etag

      assert_equal 303, last_response.status
      assert_includes store.contact("ada").vcard.to_s, "TEL;TYPE=mobile:+1-555-\r\n 0100\r\n"
    end
  end

  # The snapshot guard: a save whose etag names a card the store no
  # longer holds is refused with a toast, and nothing is written —
  # another tab or a client sync edited the contact in between, and
  # the save would have reverted it.
  def test_a_save_over_a_stale_snapshot_is_refused
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "King", etag: '"stale"'

      assert_equal 200, last_response.status
      assert_includes last_response.body,
        '<div role="status" data-fixed><span>This contact changed since the page loaded; nothing was saved.</span></div>'
      # The refusal re-renders the screen from the current card.
      assert_includes last_response.body, 'value="Ada"'
      assert_includes store.contact("ada").vcard.to_s, "FN:Ada Lovelace"
    end
  end

  # The backstop for the one request no browser can send (the first
  # field is required): a refused save, nothing written — N and FN are
  # mandatory, so a name blank throughout cannot be saved.
  def test_a_nameless_edit_is_refused_with_a_toast
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: " ", last: "", etag: store.contact("ada").etag

      assert_equal 200, last_response.status
      assert_includes last_response.body, '<div role="status" data-fixed><span>A contact needs a name.</span></div>'
      assert_includes store.contact("ada").vcard.to_s, "FN:Ada Lovelace"
    end
  end

  def test_saving_an_unknown_contact_is_404
    with_contacts({}) { post "/contacts/nope", first: "No", etag: '"x"' }

    assert_equal 404, last_response.status
  end
end
