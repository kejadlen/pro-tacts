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

  # The caption row's height comes from .record-nav's own inherited
  # line box, not from the type-label inside it (see admin.css), so
  # the two record pages have to open the block the same way. A bare
  # link on one of them is the shorter row, and the card under it —
  # along with the line itself — moves when you switch modes.
  def test_both_record_pages_open_the_block_with_the_same_row
    with_contacts({"ada" => ADA}) do
      get "/contacts/ada"
      show = last_response.body

      get "/contacts/ada/edit"
      edit = last_response.body

      {"details" => show, "edit" => edit}.each do |page, body|
        record = body.split('<div class="record">').last
        assert_match(/\A<div class="record-nav"><a href="[^"]+" class="type-label">/,
          record, "the #{page} page opens .record with a different row")
      end
    end
  end

  # Every asset the layout asks for is this app's own. The webfont
  # that used to be linked here came from Google, and the self-hosted
  # faces meant to replace it were never added — the @font-face rules
  # pointed at three files that 404ed. Both are gone, and
  # --gl-font-mono falls through to the platform's own monospace.
  # Alpine is vendored beside the Gloss CSS for the same reason (see
  # tasks/alpine.rake): this app is reachable only over Tailscale.
  def test_the_layout_asks_for_nothing_off_this_host
    with_contacts({}) do
      get "/"

      head = last_response.body.split("</head>").first
      refute_includes head, "fonts.googleapis.com"
      refute_includes head, "fonts.gstatic.com"
      refute_includes head, "ibm-plex-mono"
      assert_includes head, '<script defer src="/vendor/alpine/alpine.min.js"></script>'
      assert_empty head.scan(%r{(?:href|src)="(https?:)?//[^"]*"}),
        "the layout links something off this host"
    end
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
      assert_includes body,
        '<label class="field" data-blank-removes><span>Nickname</span>' \
        '<input type="text" name="nickname" value="Red" placeholder="removed on save"></label>'
      assert_includes body,
        "<textarea name=\"note\" rows=\"4\" placeholder=\"removed on save\">Countess of Lovelace.</textarea>"
      # The etag carries its quotes, HTML-escaped in the attribute.
      assert_includes body, %(<input type="hidden" name="etag" value="&quot;#{store.contact("red").etag.delete('"')}&quot;">)
    end
  end

  def test_the_edit_screen_of_an_unknown_contact_is_404
    with_contacts({}) { get "/contacts/nope/edit" }

    assert_equal 404, last_response.status
  end

  # The removal state rides only where blanking deletes: nickname,
  # note, and birthday render whether or not the contact carries
  # one, and a box that rendered empty cannot lose anything — no
  # attribute, no "removed on save" in it, no remove button.
  def test_rows_without_a_property_to_lose_state_no_removal
    bare = ADA.sub("NOTE:Countess of Lovelace.\r\n", "").sub("BDAY:1985-12-10\r\n", "")

    with_contacts({"ada" => bare}) do
      get "/contacts/ada/edit"

      body = last_response.body
      assert_includes body, '<label class="field"><span>Nickname</span><input type="text" name="nickname"></label>'
      assert_includes body, '<textarea name="note" rows="4"></textarea>'
      assert_includes body, '<div class="field"><span>birthday</span><div class="date-row">'
      refute_includes body, "icon-button"
    end
  end

  # A po box has no field, and the save's removal is blank throughout,
  # po box included (Web#address_line) — so a line surviving by its po
  # box alone cannot be removed from this form, and its row, blank as
  # it renders, wears no removal state.
  def test_a_po_box_only_address_row_wears_no_removal_state
    po = ADA.sub(
      "ADR;TYPE=home:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom",
      "ADR;TYPE=home:PO Box 1;;;;;",
    )

    with_contacts({"ada" => po}) do
      get "/contacts/ada/edit"

      assert_includes last_response.body,
        '<div class="field"><span>home</span><div class="field-stack">'
    end
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

  ## Editing phones

  # The phone rows: one value field per line, named by the line's
  # digest — the address the save substitutes — beside the type's own
  # caption. The blank row a new phone goes in is in the add dialog,
  # not the card (see below).
  def test_the_edit_screen_renders_a_digest_named_field_per_phone
    with_contacts({"ada" => ADA}) do |store|
      get "/contacts/ada/edit"

      digest = store.contact("ada").phones.first.line.digest
      body = last_response.body
      assert_includes body,
        '<label class="field" data-blank-removes><span>mobile</span>' \
        '<input type="tel" name="phone[' + digest + ']" value="+1-555-0100" placeholder="removed on save"></label>'
    end
  end

  ## Editing emails

  # The email rows: the phone row's own shape over EMAIL — one value
  # field per line, named by the line's digest, beside the type's own
  # caption.
  def test_the_edit_screen_renders_a_digest_named_field_per_email
    with_contacts({"ada" => ADA}) do |store|
      get "/contacts/ada/edit"

      digest = store.contact("ada").emails.first.line.digest
      assert_includes last_response.body,
        '<label class="field" data-blank-removes><span>home</span>' \
        '<input type="email" name="email[' + digest + ']" value="ada@example.com" placeholder="removed on save"></label>'
    end
  end

  # The addressed edit at work over EMAIL: the submitted row swaps its
  # line's value under the line's own header, and every other byte of
  # the stored card — the other EMAIL-able lines included — stands
  # untouched.
  def test_saving_a_changed_email_replaces_only_its_line
    two = ADA.sub("EMAIL;TYPE=home:ada@example.com\r\n",
                  "EMAIL;TYPE=home:ada@example.com\r\nEMAIL;TYPE=work:countess@example.com\r\n")

    with_contacts({"ada" => two}) do |store|
      digest = store.contact("ada").emails.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               email: {digest => "lovelace@example.com"}

      assert_equal 303, last_response.status
      card = store.contact("ada").vcard.to_s
      assert_includes card, "EMAIL;TYPE=home:lovelace@example.com\r\n"
      assert_includes card, "EMAIL;TYPE=work:countess@example.com\r\n"
      refute_includes card, "ada@example.com"
    end
  end

  # The header is the line's own, kept byte for byte — the phones'
  # own rule, over the parameters an EMAIL line can carry.
  def test_a_saved_email_keeps_its_lines_own_parameters
    apple = ADA.sub("EMAIL;TYPE=home:ada@example.com", "EMAIL;type=INTERNET;type=HOME;type=pref:ada@example.com")

    with_contacts({"ada" => apple}) do |store|
      digest = store.contact("ada").emails.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               email: {digest => "lovelace@example.com"}

      assert_equal 303, last_response.status
      assert_includes store.contact("ada").vcard.to_s,
        "EMAIL;type=INTERNET;type=HOME;type=pref:lovelace@example.com\r\n"
    end
  end

  # Blank equals absent for a row with a digest: the blank removes
  # the line, the phones' own rule.
  def test_a_blank_email_row_removes_the_line
    with_contacts({"ada" => ADA}) do |store|
      digest = store.contact("ada").emails.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               email: {digest => " "}

      assert_equal 303, last_response.status
      refute_includes store.contact("ada").vcard.to_s, "EMAIL"
    end
  end

  # An unchanged row never rewrites its line, and the whole save
  # leaves the stored card byte for byte as it lay.
  def test_an_unchanged_email_and_address_leave_the_stored_card_byte_identical
    with_contacts({"ada" => ADA}) do |store|
      before = store.contact("ada").stored.to_s
      email_digest = store.contact("ada").emails.first.line.digest
      address_digest = store.contact("ada").addresses.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", note: "Countess of Lovelace.",
                               etag: store.contact("ada").etag, new_email: "",
                               email: {email_digest => "ada@example.com"},
                               address: {address_digest => {
                                 "street" => "12 Analytical Way", "locality" => "London",
                                 "region" => "England", "postal_code" => "NW1 1AA",
                                 "country" => "United Kingdom",
                               }}

      assert_equal 303, last_response.status
      assert_equal before, store.contact("ada").stored.to_s
    end
  end

  # The revealed row: a value lands as a bare EMAIL before END:VCARD,
  # and a blank one inserts nothing — the phones' own rules.
  def test_an_added_email_lands_as_a_bare_email_before_the_end
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               new_email: ["lovelace@example.com", "", "countess@example.com"]

      assert_equal 303, last_response.status
      card = store.contact("ada").vcard.to_s
      assert_equal ["ada@example.com", "lovelace@example.com", "countess@example.com"],
        store.contact("ada").emails.map(&:value)
      assert_includes card, "EMAIL:countess@example.com\r\nBDAY:1985-12-10\r\nEND:VCARD\r\n"
    end
  end

  ## Editing addresses

  # An address row: the type's caption and a stack of component
  # fields in the value column, each named by the row's digest and
  # its component — and no po box field, which the save preserves
  # raw rather than letting a form near it.
  def test_the_edit_screen_renders_component_fields_per_address
    with_contacts({"ada" => ADA}) do |store|
      get "/contacts/ada/edit"

      digest = store.contact("ada").addresses.first.line.digest
      body = last_response.body
      assert_includes body,
        '<div class="field" data-blank-removes><span>home</span><div class="field-stack">' \
        '<input type="text" name="address[' + digest + '][street]" value="12 Analytical Way" placeholder="street" aria-label="street">' \
        '<input type="text" name="address[' + digest + '][extended]" placeholder="street 2" aria-label="street 2">' \
        '<input type="text" name="address[' + digest + '][locality]" value="London" placeholder="city" aria-label="city">'
      assert_includes body,
        'name="address[' + digest + '][postal_code]" value="NW1 1AA" placeholder="postal code"'
      assert_includes body,
        'name="address[' + digest + '][country]" value="United Kingdom" placeholder="country"'
      refute_includes body, "po_box"
    end
  end

  # The addressed edit at work over ADR: the submitted components
  # swap under the line's own header, and every other byte of the
  # stored card stands untouched.
  def test_saving_a_changed_address_replaces_only_its_line
    with_contacts({"ada" => ADA}) do |store|
      digest = store.contact("ada").addresses.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               address: {digest => {
                                 "street" => "5 Analytical Way", "locality" => "London",
                                 "region" => "England", "postal_code" => "NW1 1AA",
                                 "country" => "United Kingdom",
                               }}

      assert_equal 303, last_response.status
      card = store.contact("ada").vcard.to_s
      assert_includes card, "ADR;TYPE=home:;;5 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n"
      assert_includes card, "TEL;TYPE=mobile:+1-555-0100\r\n"
      assert_includes card, "EMAIL;TYPE=home:ada@example.com\r\n"

      follow_redirect!
      assert_includes last_response.body, "5 Analytical Way"
    end
  end

  # The header is the line's own, kept byte for byte — the phones'
  # own rule, over the parameters an ADR line can carry.
  def test_a_saved_address_keeps_its_lines_own_parameters
    apple = ADA.sub(
      "ADR;TYPE=home:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom",
      "ADR;type=HOME;type=pref:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom",
    )

    with_contacts({"ada" => apple}) do |store|
      digest = store.contact("ada").addresses.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               address: {digest => {
                                   "street" => "5 Analytical Way", "locality" => "London",
                                   "region" => "England", "postal_code" => "NW1 1AA",
                                   "country" => "United Kingdom",
                                 }}

      assert_equal 303, last_response.status
      assert_includes store.contact("ada").vcard.to_s,
        "ADR;type=HOME;type=pref:;;5 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n"
    end
  end

  # Removal is the reader's own rule: a row blank throughout, po box
  # included, removes the line.
  def test_an_address_row_blank_throughout_removes_the_line
    with_contacts({"ada" => ADA}) do |store|
      digest = store.contact("ada").addresses.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               address: {digest => {
                                   "street" => " ", "extended" => "", "locality" => "",
                                   "region" => "", "postal_code" => "", "country" => "",
                                 }}

      assert_equal 303, last_response.status
      refute_includes store.contact("ada").vcard.to_s, "ADR"
    end
  end

  # A partially blanked row keeps its line — partial blanks are legal
  # empty components, the reader's own rule in the other direction.
  def test_a_partially_blanked_address_keeps_the_line
    with_contacts({"ada" => ADA}) do |store|
      digest = store.contact("ada").addresses.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               address: {digest => {
                                   "street" => "12 Analytical Way", "locality" => "London",
                                   "region" => "", "postal_code" => "", "country" => "",
                                 }}

      assert_equal 303, last_response.status
      assert_includes store.contact("ada").vcard.to_s,
        "ADR;TYPE=home:;;12 Analytical Way;London;;;\r\n"
    end
  end

  # The po box and any component the form left alone keep their own
  # bytes — n_line's splice rule at the component grain, where a
  # rebuild through unescape and re-escape is not byte-stable (the
  # unrecognized `\\q` escape would come back doubled).
  def test_the_addresss_untouched_components_are_preserved_byte_for_byte
    po_box = ADA.sub(
      "ADR;TYPE=home:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom",
      "ADR;TYPE=home:P.O. Box 5;Apt \\q;12 Way\\, West;London;England;NW1 1AA;United Kingdom",
    )

    with_contacts({"ada" => po_box}) do |store|
      digest = store.contact("ada").addresses.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               address: {digest => {
                                   "street" => "12 Way, West", "extended" => "Apt \\q",
                                   "locality" => "Manchester", "region" => "England",
                                   "postal_code" => "NW1 1AA", "country" => "United Kingdom",
                                 }}

      assert_equal 303, last_response.status
      assert_includes store.contact("ada").vcard.to_s,
        "ADR;TYPE=home:P.O. Box 5;Apt \\q;12 Way\\, West;Manchester;England;NW1 1AA;United Kingdom\r\n"
    end
  end

  # A component is text and the value is structure: punctuation
  # escapes in the written line (RFC 2426 section 2.4.2).
  def test_address_punctuation_escapes_in_the_written_line
    with_contacts({"ada" => ADA}) do |store|
      digest = store.contact("ada").addresses.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               address: {digest => {
                                   "street" => "12 Way, East; Annexe", "locality" => "London",
                                   "region" => "England", "postal_code" => "NW1 1AA",
                                   "country" => "United Kingdom",
                                 }}

      assert_equal 303, last_response.status
      assert_includes store.contact("ada").vcard.to_s,
        "ADR;TYPE=home:;;12 Way\\, East\\; Annexe;London;England;NW1 1AA;United Kingdom\r\n"
    end
  end

  # The revealed address row: the components land in the value's own
  # order — po box empty, extended before street (RFC 2426 section
  # 3.2.1) — whatever order the form stacks them in, and a row blank
  # throughout inserts nothing, the new-row rule.
  def test_an_added_address_lands_in_component_order_before_the_end
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               new_address: {"1" => {
                                   "street" => "5 Analytical Way", "extended" => "Apt 9",
                                   "locality" => "London", "country" => "United Kingdom",
                                 }}

      assert_equal 303, last_response.status
      card = store.contact("ada").vcard.to_s
      assert_includes card, "ADR:;Apt 9;5 Analytical Way;London;;;United Kingdom\r\nBDAY:1985-12-10\r\nEND:VCARD\r\n"
      assert_includes card, "ADR;TYPE=home:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n"
    end
  end

  def test_a_blank_address_add_row_inserts_nothing
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               new_address: {"0" => {"street" => " ", "country" => ""}}

      assert_equal 303, last_response.status
      assert_equal 1, store.contact("ada").addresses.length
    end
  end

  ## Editing the birthday

  # The one row that saves to the model rather than the card: the
  # prefill is Contact#birthday, three controls on one line — a month
  # select (names, constrained by construction) and ranged number
  # inputs — in the value column, month-day-year matching the prose
  # the details page renders.
  def test_the_edit_screen_renders_the_birthday_row
    with_contacts({"ada" => ADA}) do
      get "/contacts/ada/edit"

      body = last_response.body
      assert_includes body,
        '<div class="field" data-blank-removes><span>birthday</span><div class="date-row">' \
        '<select name="birthday[month]" aria-label="month"><option value="">month</option>'
      assert_includes body, '<option value="12" selected>December</option></select>'
      assert_includes body,
        '<input type="number" name="birthday[day]" value="10" min="1" max="31" placeholder="day" aria-label="day">'
      assert_includes body,
        '<input type="number" name="birthday[year]" value="1985" min="1" max="9999" placeholder="year" aria-label="year">'
      # The remove control: one click that speaks the three-blank
      # rule, over a held birthday only — Gloss's IconButton, so the
      # glyph carries the label.
      assert_includes body,
        %(<button type="button" class="icon-button" data-size="sm" aria-label="Remove birthday" @click="$el.closest('.date-row').querySelectorAll('select, input').forEach(el => el.value = '')"><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden><path d="M18 6 6 18"></path><path d="m6 6 12 12"></path></svg></button>)
    end
  end

  # A birthday edit is a model write: the served card composes the new
  # BDAY, the stored bytes never move, and the change-log entry carries
  # the new composed etag — a client's token sees what a device
  # downloads (Store#rewrite).
  def test_saving_a_changed_birthday_moves_the_served_card_only
    with_contacts({"ada" => ADA}) do |store|
      before = store.contact("ada").stored.to_s
      post "/contacts/ada", first: "Ada", last: "Lovelace", note: "Countess of Lovelace.",
                               etag: store.contact("ada").etag,
                               birthday: {"month" => "4", "day" => "12", "year" => "1990"}

      assert_equal 303, last_response.status
      contact = store.contact("ada")
      assert_equal before, contact.stored.to_s
      assert_includes contact.vcard.to_s, "BDAY:1990-04-12\r\n"
      assert_equal contact.etag, store.changes.last.etag

      follow_redirect!
      assert_includes last_response.body, "April 12, 1990"
    end
  end

  # A birthday without a year is the one partial shape the wire
  # carries — composed as Apple's sentinel, the form a client has been
  # verified to accept (docs/plans/2026-08-31-partial-birthdays.md).
  def test_a_birthday_without_a_year_is_saved_and_served_apples_way
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               birthday: {"month" => "12", "day" => "10", "year" => ""}

      assert_equal 303, last_response.status
      assert_includes store.contact("ada").vcard.to_s,
        "BDAY;X-APPLE-OMIT-YEAR=1604:1604-12-10\r\n"
    end
  end

  # The shapes no client renders are editable all the same — the model
  # holds them, the web UI shows them, and nothing composes on their
  # behalf: their documented fate.
  def test_a_month_alone_is_saved_and_serves_nothing
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               birthday: {"month" => "4", "day" => "", "year" => ""}

      assert_equal 303, last_response.status
      contact = store.contact("ada")
      assert_equal ProTacts::Birthday.new(month: 4), contact.birthday
      refute_includes contact.vcard.to_s, "BDAY:"

      follow_redirect!
      assert_includes last_response.body, "April"
    end
  end

  # Three blanks remove the birthday, the form's blank-equals-absent —
  # the model row goes and the composed card with it.
  def test_a_blank_birthday_removes_it
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               birthday: {"month" => "", "day" => "", "year" => ""}

      assert_equal 303, last_response.status
      contact = store.contact("ada")
      assert_nil contact.birthday
      refute_includes contact.vcard.to_s, "BDAY"
    end
  end

  # A POST from anything but this form carries no birthday group and
  # keeps the model, the phones' is-a-Hash posture — a group the
  # request never carried touches nothing.
  def test_a_save_without_birthday_fields_leaves_the_model_alone
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag

      assert_equal 303, last_response.status
      assert_equal ProTacts::Birthday.new(year: 1985, month: 12, day: 10),
        store.contact("ada").birthday
    end
  end

  # A shape the grammar refuses — a year and a day with no month
  # between them — is a toast and nothing written: the constructor's
  # ArgumentError is the refusal, caught where a re-render is the
  # fallback. The browser's number inputs make this a hand-crafted
  # POST's own, the name toast's backstop sibling.
  def test_a_year_and_day_without_a_month_is_refused
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               birthday: {"month" => "", "day" => "12", "year" => "1985"}

      assert_equal 200, last_response.status
      assert_includes last_response.body,
        '<div role="status" data-fixed><span>That birthday is not a shape a date can take.</span></div>'
      assert_equal ProTacts::Birthday.new(year: 1985, month: 12, day: 10),
        store.contact("ada").birthday
    end
  end

  def test_nonsense_in_a_birthday_field_is_refused
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               birthday: {"month" => "4", "day" => "12", "year" => "19x5"}

      assert_equal 200, last_response.status
      assert_includes last_response.body, "That birthday is not a shape a date can take."
      assert_equal ProTacts::Birthday.new(year: 1985, month: 12, day: 10),
        store.contact("ada").birthday
    end
  end

  # The one state the row cannot write: a stored card carrying its own
  # BDAY spelling (the model refused it, so it stayed in the card) — a
  # submitted birthday would compose a second BDAY beside it. Refused
  # whole, name edit included: one submit, one write.
  def test_a_birthday_against_a_cards_own_spelling_is_refused
    resident = ADA.sub("BDAY:1985-12-10\r\n", "BDAY:1985-04\r\n")

    with_contacts({"ada" => resident}) do |store|
      assert_nil store.contact("ada").birthday

      post "/contacts/ada", first: "Grace", last: "Hopper", etag: store.contact("ada").etag,
                               birthday: {"month" => "4", "day" => "", "year" => "1985"}

      assert_equal 200, last_response.status
      assert_includes last_response.body,
        '<div role="status" data-fixed><span>This contact&#39;s card carries its own birthday spelling; nothing was saved.</span></div>'
      contact = store.contact("ada")
      assert_nil contact.birthday
      assert_equal 1, contact.vcard.to_s.scan("BDAY").length
      assert_includes contact.vcard.to_s, "BDAY:1985-04\r\n"
      assert_includes contact.vcard.to_s, "FN:Ada Lovelace\r\n"
    end
  end

  ## Adding a property

  # The add affordance: a trigger on the back link's line — the place
  # the details page puts its edit link — and a dialog that names
  # types rather than collecting values.
  def test_the_edit_screen_opens_an_add_dialog_from_the_record_nav
    with_contacts({"ada" => ADA}) do
      get "/contacts/ada/edit"

      body = last_response.body
      assert_includes body,
        '<a href="/contacts/ada" class="type-label">‹ Ada Lovelace</a>' \
        '<button type="button" data-size="sm" popovertarget="add-property">add property</button></div>'
      assert_includes body, '<dialog id="add-property" popover="auto">'
      # A radio group of every kind the save can insert: ADDABLE_TYPES
      # is the list. The shared `name` is what makes them a native
      # group; it is never submitted, the dialog having no form owner.
      assert_includes body,
        '<div class="field-stack" role="radiogroup" aria-label="Type">' \
        '<label><input type="radio" name="add-type" value="phone" x-model="type">phone</label>' \
        '<label><input type="radio" name="add-type" value="email" x-model="type">email</label>' \
        '<label><input type="radio" name="add-type" value="address" x-model="type">address</label></div>'
      assert_includes body,
        '<button type="button" popovertarget="add-property" popovertargetaction="hide">Cancel</button>'
      # Add makes the row and then hides the popover, in that order —
      # the row has to exist before x-init's focus can land on it.
      assert_includes body, %(@click="added.push(type); $el.closest('dialog').hidePopover()")
    end
  end

  # The card carries no blank row at rest: the rows are a template
  # Alpine fills from `added`, so none stands waiting to be used and
  # none lingers after one is. The dialog and the form share a scope
  # because Alpine scopes by ancestry.
  def test_added_rows_are_a_template_the_dialog_appends_to
    with_contacts({"ada" => ADA}) do
      body = (get("/contacts/ada/edit") && last_response.body)

      assert_includes body, %(<div x-data="{ added: [], type: 'phone' }">)
      # One template serves every kind: the single-value kinds get an
      # input whose type and name bind to the kind, the address kind
      # the same six component fields a standing row gets — named by
      # the add index, there being no line yet to digest.
      assert_includes body,
        '<template x-for="(kind, i) in added" :key="i"><div class="field">' \
        '<span x-text="kind"></span>' \
        '<template x-if="kind !== \'address\'">' \
        '<input :type="kind === \'phone\' ? \'tel\' : kind" :name="`new_${kind}[]`" :aria-label="kind" x-init="$el.focus()">' \
        '</template>' \
        '<template x-if="kind === \'address\'">' \
        '<div class="field-stack">' \
        '<input type="text" :name="`new_address[${i}][street]`" placeholder="street" aria-label="street" x-init="$el.focus()">' \
        '<input type="text" :name="`new_address[${i}][extended]`" placeholder="street 2" aria-label="street 2">' \
        '<input type="text" :name="`new_address[${i}][locality]`" placeholder="city" aria-label="city">' \
        '<input type="text" :name="`new_address[${i}][region]`" placeholder="region" aria-label="region">' \
        '<input type="text" :name="`new_address[${i}][postal_code]`" placeholder="postal code" aria-label="postal code">' \
        '<input type="text" :name="`new_address[${i}][country]`" placeholder="country" aria-label="country">' \
        '</div></template></div></template>'
      # The template is inside the edit form, so one Save writes every
      # row it made along with everything else. Indexed from the
      # form's start, the header's search form closing before both.
      edit_form = body.index('<form action="/contacts/ada" method="post"')
      assert_operator body.index("<template"), :<, body.index("</form>", edit_form)
      # No standing row, and no field the server would read if Alpine
      # never ran.
      refute_includes body, 'name="new_phone[]"'
    end
  end

  # One pass adds as many phones as rows were made for it. The blanks
  # among them are rows nobody typed in, and they cost nothing.
  def test_a_single_save_adds_every_phone_that_was_typed
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               new_phone: ["+1-555-0177", "+1-555-0188", "", ""]

      assert_equal 303, last_response.status
      assert_equal ["+1-555-0100", "+1-555-0177", "+1-555-0188"],
        store.contact("ada").phones.map(&:value)
    end
  end

  # The addressed edit at work: the submitted row swaps its line's
  # value under the line's own header, and every other byte of the
  # stored card — the other TEL-able lines included — stands
  # untouched.
  def test_saving_a_changed_phone_replaces_only_its_line
    two = ADA.sub("TEL;TYPE=mobile:+1-555-0100\r\n", "TEL;TYPE=mobile:+1-555-0100\r\nTEL;TYPE=work:+1-555-0199\r\n")

    with_contacts({"ada" => two}) do |store|
      digest = store.contact("ada").phones.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               phone: {digest => "+1-555-0150"}

      assert_equal 303, last_response.status
      card = store.contact("ada").vcard.to_s
      assert_includes card, "TEL;TYPE=mobile:+1-555-0150\r\n"
      assert_includes card, "TEL;TYPE=work:+1-555-0199\r\n"
      refute_includes card, "+1-555-0100"

      follow_redirect!
      assert_includes last_response.body, "+1-555-0150"
    end
  end

  # The header is the line's own, kept byte for byte: macOS writes
  # three TYPE parameters on one TEL, and a save that rebuilt the
  # header from a type field would drop the two the form never
  # showed. The value is the only thing that moves.
  def test_a_saved_phone_keeps_its_lines_own_parameters
    apple = ADA.sub("TEL;TYPE=mobile:+1-555-0100", "TEL;type=CELL;type=VOICE;type=pref:+1-555-0100")

    with_contacts({"ada" => apple}) do |store|
      digest = store.contact("ada").phones.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               phone: {digest => "+1-555-0150"}

      assert_equal 303, last_response.status
      assert_includes store.contact("ada").vcard.to_s,
        "TEL;type=CELL;type=VOICE;type=pref:+1-555-0150\r\n"
    end
  end

  # Blank equals absent for a row with a digest: the blank removes
  # the line, the reader's own rule in the other direction. The FN
  # assertion keeps an empty-card regression from passing vacuously.
  def test_a_blank_phone_row_removes_the_line
    with_contacts({"ada" => ADA}) do |store|
      digest = store.contact("ada").phones.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               phone: {digest => " "}

      assert_equal 303, last_response.status
      card = store.contact("ada").vcard.to_s
      refute_includes card, "TEL"
      assert_includes card, "FN:Ada Lovelace\r\n"
    end
  end

  # An unchanged row never rewrites its line — byte identity by
  # construction, not by faithful re-rendering — and the whole save
  # leaves the stored card byte for byte as it lay.
  def test_an_unchanged_phone_leaves_the_stored_card_byte_identical
    with_contacts({"ada" => ADA}) do |store|
      before = store.contact("ada").stored.to_s
      digest = store.contact("ada").phones.first.line.digest
      post "/contacts/ada", first: "Ada", last: "Lovelace", note: "Countess of Lovelace.",
                               etag: store.contact("ada").etag, new_phone: "",
                               phone: {digest => " +1-555-0100 "}

      assert_equal 303, last_response.status
      assert_equal before, store.contact("ada").stored.to_s
    end
  end

  # The revealed row: a value lands as a bare TEL before
  # END:VCARD — the served card composes the BDAY in under it — and a
  # blank one inserts nothing, inserting absence being a no-op.
  def test_an_added_phone_lands_as_a_bare_tel_before_the_end
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               new_phone: "+1 (555) 020-0700, x9"

      assert_equal 303, last_response.status
      card = store.contact("ada").vcard.to_s
      assert_includes card, "TEL:+1 (555) 020-0700\\, x9\r\nBDAY:1985-12-10\r\nEND:VCARD\r\n"
      assert_includes card, "TEL;TYPE=mobile:+1-555-0100\r\n"
    end
  end

  def test_a_blank_add_row_inserts_nothing
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               new_phone: " "

      assert_equal 303, last_response.status
      assert_equal 1, store.contact("ada").phones.length
    end
  end

  # The addresses and emails come from the contact, never the
  # request: a doctored digest names no row and touches nothing, where
  # a doctored index into a list would have rewritten some other line.
  def test_a_digest_the_card_never_had_is_ignored
    with_contacts({"ada" => ADA}) do |store|
      post "/contacts/ada", first: "Ada", last: "Lovelace", etag: store.contact("ada").etag,
                               phone: {"0" * 64 => "+1-555-9999"},
                               email: {"1" * 64 => "x@example.com"},
                               address: {"2" * 64 => {"street" => "nowhere"}}

      assert_equal 303, last_response.status
      card = store.contact("ada").vcard.to_s
      assert_includes card, "TEL;TYPE=mobile:+1-555-0100\r\n"
      assert_includes card, "EMAIL;TYPE=home:ada@example.com\r\n"
      assert_includes card, "ADR;TYPE=home:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n"
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
