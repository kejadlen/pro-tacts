require_relative "../../test_helper"

require "pathname"
require "rack/test"
require "tmpdir"

require "pro_tacts/web"

# The import screens, exercised the way the other admin screens are:
# real requests through the Roda app against a throwaway store
# (docs/plans/2026-09-21-import-a-vcf.md).
class AdminImportPagesTest < Minitest::Test
  include Rack::Test::Methods
  include ThrowawayContacts

  JANE = <<~CARD.gsub("\n", "\r\n")
    BEGIN:VCARD
    VERSION:3.0
    N:Booles;Jane;;;
    FN:Jane Booles
    TEL;type=CELL:+1 555 0100
    item1.X-ABRELATEDNAMES:Sam Booles
    item1.X-ABLabel:_$!<Spouse>!$_
    X-SOCIALPROFILE;type=twitter:https://twitter.com/jb
    UID:ABC-123
    END:VCARD
  CARD

  PLAIN = <<~CARD.gsub("\n", "\r\n")
    BEGIN:VCARD
    VERSION:3.0
    N:Booles;Sam;;;
    FN:Sam Booles
    UID:DEF-456
    END:VCARD
  CARD

  def app
    ProTacts::Web
  end

  def setup
    header "Remote-User", "test@example.com"
  end

  # The file as a browser sends one, written out because Rack::Test
  # uploads a path. Answers with the import's id, which every screen
  # of the walk carries.
  def upload(bytes, name: "contacts.vcf")
    Dir.mktmpdir do |tmp|
      path = Pathname.new(tmp) / name
      path.binwrite(bytes)
      post "/import", "vcf" => Rack::Test::UploadedFile.new(path.to_s, "text/vcard", true)
    end
    last_response.headers["location"].to_s[%r{/import/([a-z]+)}, 1]
  end

  # The snapshot guard the editor's form carries, read off the page
  # rather than out of the store, a staged contact having no row
  # there yet. An etag wears quotes (RFC 9110 section 8.8.3) and the
  # attribute spells them as entities; a browser sends back the
  # quotes themselves.
  def etag = last_response.body[/name="etag" value="([^"]+)"/, 1].to_s.gsub("&quot;", '"')

  def test_the_screen_asks_for_a_vcf
    get "/import"

    assert_equal 200, last_response.status
    assert_includes last_response.body, %(<form action="/import" method="post" enctype="multipart/form-data")
    assert_includes last_response.body, %(<input type="file" name="vcf" accept=".vcf,text/vcard">)
  end

  def test_an_upload_is_looked_over_before_anything_lands
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)

      assert_equal 303, last_response.status
      follow_redirect!

      assert_equal 200, last_response.status
      assert_includes last_response.body, "2 contacts"
      assert_includes last_response.body, "Jane Booles"
      assert_includes last_response.body, "Sam Booles"
      assert_includes last_response.body, %(href="/import/#{id}/0")
      assert_empty store.changes
    end
  end

  # The row says what opening it would be for: a contact losing
  # nothing does not need a visit.
  def test_the_list_marks_the_contacts_losing_something
    with_contacts({}) do |_store|
      upload(JANE + PLAIN)
      follow_redirect!

      assert_includes last_response.body, "3 lines left behind"
      assert_equal 1, last_response.body.scan("left behind").length
    end
  end

  # The same fact for the file as a whole, read before deciding
  # whether the list is worth working down at all.
  def test_the_list_names_the_properties_the_file_is_losing
    with_contacts({}) do |_store|
      upload(JANE)
      follow_redirect!

      assert_includes last_response.body, "X-ABRELATEDNAMES"
      assert_includes last_response.body, "X-SOCIALPROFILE"
      assert_includes last_response.body, "1 line"
    end
  end

  def test_a_file_this_book_reads_whole_says_so
    with_contacts({}) do |_store|
      upload(PLAIN)
      follow_redirect!

      assert_includes last_response.body, "Nothing in this file needs reading before it lands."
      refute_includes last_response.body, "left behind"
    end
  end

  # Every export names the program that wrote it, and nobody is
  # going to copy that into a card: it is dropped without being
  # counted, so a file losing nothing else reads as losing nothing.
  def test_a_file_losing_only_its_exporters_name_asks_for_nothing
    with_contacts({}) do |_store|
      upload(PLAIN.sub("VERSION:3.0\r\n", "VERSION:3.0\r\nPRODID:-//Apple Inc.//macOS 15.0//EN\r\n"))
      follow_redirect!

      assert_includes last_response.body, "Nothing in this file needs reading before it lands."
      refute_includes last_response.body, "left behind"
      refute_includes last_response.body, "PRODID"
    end
  end

  # The card as exported still says so, though: it is the file's own
  # bytes, and a line shown plain there would be one claiming to
  # arrive.
  def test_the_exporters_name_is_struck_on_the_card_it_arrived_on
    with_contacts({}) do |store|
      id = upload(PLAIN.sub("VERSION:3.0\r\n", "VERSION:3.0\r\nPRODID:-//Apple Inc.//macOS 15.0//EN\r\n"))

      get "/import/#{id}/0"

      assert_includes last_response.body,
                      %(<li data-dropped><span>PRODID:-//Apple Inc.//macOS 15.0//EN</span>)

      post "/import/#{id}/land", "group" => ""

      refute_includes store.contacts.fetch(0).vcard.to_s, "PRODID"
    end
  end

  # The two cards: the contact as the file wrote it, and the contact
  # that is landing, open in the editor.
  def test_a_contact_opens_beside_the_card_it_arrived_as
    with_contacts({}) do |_store|
      id = upload(JANE)

      get "/import/#{id}/0"

      assert_equal 200, last_response.status
      assert_includes last_response.body, %(<div class="paired">)
      assert_includes last_response.body, "as exported"
      # Every line of the original, struck where it is not coming in.
      assert_includes last_response.body, "TEL;type=CELL:+1 555 0100"
      assert_includes last_response.body,
                      %(<li data-dropped><span>X-SOCIALPROFILE;type=twitter:https://twitter.com/jb</span>)
      assert_includes last_response.body, "not imported"
      # And the editor, pre-filled and pointed at the import.
      assert_includes last_response.body, %(<form action="/import/#{id}/0" method="post")
      assert_includes last_response.body, %(value="+1 555 0100")
      assert_includes last_response.body, %(href="/import/#{id}")
    end
  end

  def test_an_index_past_the_end_of_the_file_is_not_found
    with_contacts({}) do |_store|
      id = upload(JANE)

      get "/import/#{id}/7"

      assert_equal 404, last_response.status
    end
  end

  # The point of the pair: read what is being left behind on the
  # left, and put what matters into the card on the right.
  def test_an_edit_is_held_against_the_contact_until_the_import_lands
    with_contacts({}) do |store|
      id = upload(JANE)
      get "/import/#{id}/0"

      post "/import/#{id}/0",
           "etag" => etag, "first" => "Jane", "middle" => "", "last" => "Booles",
           "nickname" => "", "note" => "Spouse: Sam Booles"

      assert_equal 303, last_response.status
      assert_empty store.changes

      post "/import/#{id}/land", "group" => ""

      assert_includes store.contacts.fetch(0).vcard.to_s, "NOTE:Spouse: Sam Booles"
    end
  end

  # The editor's own guard, over the staged card: two tabs on one
  # import, and the second save would revert the first.
  def test_a_save_against_a_stale_card_is_refused
    with_contacts({}) do |_store|
      id = upload(JANE)
      get "/import/#{id}/0"

      post "/import/#{id}/0",
           "etag" => "not the etag", "first" => "Jane", "middle" => "", "last" => "Booles",
           "nickname" => "", "note" => "lost"

      assert_includes last_response.body, "This card changed since the page loaded"
      refute_includes last_response.body, "lost"
    end
  end

  # The birthday is the one field the editor holds in the model
  # rather than in the card, and a staged contact has no model: the
  # save writes it back as the BDAY line it will land as.
  def test_a_birthday_typed_on_the_import_lands_with_the_contact
    with_contacts({}) do |store|
      id = upload(JANE)
      get "/import/#{id}/0"

      post "/import/#{id}/0",
           "etag" => etag, "first" => "Jane", "middle" => "", "last" => "Booles",
           "nickname" => "", "note" => "",
           "birthday" => { "year" => "1985", "month" => "4", "day" => "12" }

      assert_equal 303, last_response.status

      post "/import/#{id}/land", "group" => ""

      assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12), store.contacts.fetch(0).birthday
    end
  end

  # And the shape no card can spell is refused rather than dropped:
  # the model that holds a partial birthday does not exist until the
  # contact lands (docs/plans/2026-08-31-partial-birthdays.md).
  def test_a_birthday_no_card_can_spell_is_refused_until_the_contact_lands
    with_contacts({}) do |_store|
      id = upload(JANE)
      get "/import/#{id}/0"

      post "/import/#{id}/0",
           "etag" => etag, "first" => "Jane", "middle" => "", "last" => "Booles",
           "nickname" => "", "note" => "",
           "birthday" => { "year" => "1985", "month" => "", "day" => "" }

      assert_equal 200, last_response.status
      assert_includes last_response.body, "A card cannot hold a birthday that partial until it lands."
    end
  end

  # The groups this book already has, offered beside the name the
  # import would make: an import is as often people who belong in a
  # group that exists as it is a batch that only needs finding again.
  def test_the_review_offers_the_groups_this_book_already_has
    with_contacts({}) do |store|
      school = store.create_group(name: "school")

      upload(JANE)
      follow_redirect!

      assert_includes last_response.body, %(<input type="text" name="group" value="import-)
      assert_includes last_response.body, %(<input type="checkbox" name="groups[]" value="#{school}">school)
    end
  end

  # Ticked and typed are both joins. The id that names no group is
  # dropped rather than carried into Store#add_member, which reads a
  # group with `sole` and would answer bad input with a 500.
  def test_confirming_joins_the_groups_that_were_ticked
    with_contacts({}) do |store|
      school = store.create_group(name: "school")
      id = upload(JANE)

      post "/import/#{id}/land", "group" => "import-20260921T031655Z", "groups" => [school, "zzzz"]

      assert_equal 200, last_response.status
      landed = store.contacts.fetch(0)

      assert_equal [landed.id], store.group(school).members
      assert_equal ["import-20260921T031655Z", "school", ProTacts::Store::EVERYONE],
                   store.all_groups.select { it.members.include?(landed.id) }.map(&:name).sort
    end
  end

  def test_confirming_lands_the_contacts_as_they_stand
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)

      post "/import/#{id}/land", "group" => "import-20260921T031655Z"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "landed (2)"
      assert_equal 2, store.contacts.length
      assert_includes store.all_groups.map(&:name), "import-20260921T031655Z"

      jane = store.contacts.find { it.name == "Jane Booles" }

      assert_includes jane.vcard.to_s, "TEL;type=CELL:+1 555 0100"
      refute_includes jane.vcard.to_s, "X-SOCIALPROFILE"
      refute_includes jane.vcard.to_s, "X-ABRELATEDNAMES"
      assert_includes last_response.body, %(href="/contacts/#{jane.id}")
    end
  end

  # Swept out from under a screen left open, or a confirm submitted
  # twice: the import is gone and only the person has another copy.
  def test_a_confirm_with_no_staged_import_lands_nothing
    with_contacts({}) do |store|
      id = upload(JANE)

      post "/import/#{id}/land", "group" => ""
      post "/import/#{id}/land", "group" => ""

      assert_includes last_response.body, "That import is no longer here."
      assert_equal 1, store.contacts.length
    end
  end

  # An id off a link is a path if nothing checks it, so only the
  # shape this server mints reaches the disk at all.
  def test_an_import_id_this_server_never_minted_reads_nothing
    with_contacts({}) do |store|
      refute ProTacts::ChangeId.minted?("notminted")

      post "/import/notminted/land", "group" => ""

      assert_includes last_response.body, "That import is no longer here."
      assert_empty store.changes
    end
  end

  def test_an_upload_with_no_file_says_what_to_choose
    with_contacts({}) do |store|
      post "/import"

      assert_includes last_response.body, "Choose a .vcf file to import."
      assert_empty store.changes
    end
  end

  def test_a_file_that_is_not_a_set_of_vcards_stages_nothing
    with_contacts({}) do |store|
      upload("hello\r\n")

      assert_equal 200, last_response.status
      assert_includes last_response.body, "a line outside a card"
      assert_empty store.changes
    end
  end

  # Web#write_card's rule over the one other body this app reads:
  # bytes that are not the text they claim to be are refused where
  # they are read, rather than at the insert that would 500 on them.
  def test_a_file_that_is_not_utf_8_stages_nothing
    with_contacts({}) do |store|
      upload(JANE.b.sub("Jane".b, "Jan\xFF".b))

      assert_includes last_response.body, "contacts.vcf is not UTF-8 text."
      assert_empty store.changes
    end
  end
end
