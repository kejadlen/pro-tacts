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

  # A row opened and its Save pressed, which is the import of that one
  # contact: the fields the editor always sends, over the etag the
  # page it came from was rendered with.
  def save(id, index, first:, last:, **params)
    get "/import/#{id}/#{index}"
    post "/import/#{id}/#{index}",
         {"etag" => etag, "first" => first, "middle" => "", "last" => last,
          "nickname" => "", "note" => ""}.merge(params)
  end

  def test_the_screen_asks_for_a_vcf
    get "/import"

    assert_equal 200, last_response.status
    assert_includes last_response.body, %(<form action="/import" method="post" enctype="multipart/form-data")
    assert_includes last_response.body, %(<input type="file" name="vcf" accept=".vcf,text/vcard">)
  end

  def test_an_upload_is_looked_over_before_anything_is_written
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)

      assert_equal 303, last_response.status
      follow_redirect!

      assert_equal 200, last_response.status
      assert_includes last_response.body, "2 contacts"
      assert_includes last_response.body, "Jane Booles"
      assert_includes last_response.body, "Sam Booles"
      assert_includes last_response.body, %(href="/import/#{id}/0")
      assert_includes last_response.body, "Nothing has come in yet."
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

      assert_includes last_response.body, "Nothing in this file needs reading before it comes in."
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

      assert_includes last_response.body, "Nothing in this file needs reading before it comes in."
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

      save(id, 0, first: "Sam", last: "Booles")

      refute_includes store.contacts.fetch(0).vcard.to_s, "PRODID"
    end
  end

  # The two cards: the contact as the file wrote it, and the contact
  # that is coming in, open in the editor.
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

  # The Save on a row's own screen is the import of that contact:
  # nothing waits for the end of the file.
  def test_saving_a_row_puts_that_one_contact_in_the_book
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)

      save(id, 0, first: "Jane", last: "Booles")

      assert_equal 303, last_response.status
      assert_equal 1, store.contacts.length

      jane = store.contacts.fetch(0)

      assert_equal "Jane Booles", jane.name
      # And the list it comes back to says so: the row leads to the
      # contact now, and the one nobody has opened still leads into
      # the walk.
      follow_redirect!

      assert_includes last_response.body, %(href="/contacts/#{jane.id}")
      assert_includes last_response.body, %(<span class="type-label">saved</span>)
      assert_includes last_response.body, %(href="/import/#{id}/1")
      assert_includes last_response.body, "1 contact in the book."
    end
  end

  # The point of the pair: read what is being left behind on the
  # left, and put what matters into the card on the right.
  def test_an_edit_on_the_pair_comes_in_with_the_contact
    with_contacts({}) do |store|
      id = upload(JANE)

      save(id, 0, first: "Jane", last: "Booles", "note" => "Spouse: Sam Booles")

      assert_includes store.contacts.fetch(0).vcard.to_s, "NOTE:Spouse: Sam Booles"
    end
  end

  # A row already in the book is a contact, edited where every other
  # contact is: the import's editor writes, and writing it a second
  # time would be a second contact rather than an edit of the first.
  def test_a_row_already_in_the_book_leads_to_the_contact
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)
      save(id, 0, first: "Jane", last: "Booles")
      jane = store.contacts.fetch(0)

      get "/import/#{id}/0"

      assert_equal 302, last_response.status
      assert_equal "/contacts/#{jane.id}", last_response.headers["location"]
    end
  end

  def test_a_save_pressed_twice_writes_one_contact
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)
      get "/import/#{id}/0"
      sent = etag

      2.times do
        post "/import/#{id}/0",
             "etag" => sent, "first" => "Jane", "middle" => "", "last" => "Booles",
             "nickname" => "", "note" => ""
      end

      assert_equal 1, store.contacts.length
      assert_equal "/contacts/#{store.contacts.fetch(0).id}", last_response.headers["location"]
    end
  end

  # Saving the last row ends the walk: there is nothing left to come
  # back to, so the import closes itself and says what came in.
  def test_saving_the_last_row_ends_the_import
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)
      save(id, 0, first: "Jane", last: "Booles")
      save(id, 1, first: "Sam", last: "Booles")

      assert_equal 200, last_response.status
      assert_includes last_response.body, "imported (2)"
      assert_equal 2, store.contacts.length

      jane = store.contacts.find { it.name == "Jane Booles" }

      assert_includes jane.vcard.to_s, "TEL;type=CELL:+1 555 0100"
      refute_includes jane.vcard.to_s, "X-SOCIALPROFILE"
      refute_includes jane.vcard.to_s, "X-ABRELATEDNAMES"
      assert_includes last_response.body, %(href="/contacts/#{jane.id}")

      # And the walk is gone with it.
      get "/import/#{id}"

      assert_includes last_response.body, "That import is no longer here."
    end
  end

  # A walk can be enough: what came in stays, and the rows nobody
  # opened are left behind with this copy of the file.
  def test_finishing_early_leaves_the_rest_behind
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)
      save(id, 0, first: "Jane", last: "Booles")
      follow_redirect!

      assert_includes last_response.body, "Finishing now leaves the other 1 behind."

      post "/import/#{id}/done"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "imported (1)"
      assert_equal 1, store.contacts.length
    end
  end

  # The editor's own guard, over the staged card: two tabs on one
  # import, and the second save would revert the first.
  def test_a_save_against_a_stale_card_is_refused
    with_contacts({}) do |store|
      id = upload(JANE)
      get "/import/#{id}/0"

      post "/import/#{id}/0",
           "etag" => "not the etag", "first" => "Jane", "middle" => "", "last" => "Booles",
           "nickname" => "", "note" => "lost"

      assert_includes last_response.body, "This card changed since the page loaded"
      refute_includes last_response.body, "lost"
      assert_empty store.contacts
    end
  end

  # The birthday is the one field the editor holds in the model
  # rather than in the card, and a staged contact has no model: the
  # save writes it back as the BDAY line it comes in as.
  def test_a_birthday_typed_on_the_import_comes_in_with_the_contact
    with_contacts({}) do |store|
      id = upload(JANE)

      save(id, 0, first: "Jane", last: "Booles",
                  "birthday" => {"year" => "1985", "month" => "4", "day" => "12"})

      assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12), store.contacts.fetch(0).birthday
    end
  end

  # And the shape no card can spell is refused rather than dropped:
  # the model that holds a partial birthday does not exist until the
  # contact is stored (docs/plans/2026-08-31-partial-birthdays.md).
  def test_a_birthday_no_card_can_spell_is_refused_until_the_contact_is_stored
    with_contacts({}) do |store|
      id = upload(JANE)

      save(id, 0, first: "Jane", last: "Booles",
                  "birthday" => {"year" => "1985", "month" => "", "day" => ""})

      assert_equal 200, last_response.status
      assert_includes last_response.body, "A card cannot hold a birthday that partial."
      assert_empty store.contacts
    end
  end

  # The whole file's group is named on the review screen; which of
  # this book's own groups a contact joins is asked beside that
  # contact's card, and written by the same Save as its fields.
  def test_a_contact_is_put_in_its_groups_beside_its_own_card
    with_contacts({}) do |store|
      school = store.create_group(name: "school")
      id = upload(JANE + PLAIN)

      get "/import/#{id}/0"

      assert_includes last_response.body, %(<input type="checkbox" name="groups[]" value="#{school}">school)

      save(id, 0, first: "Jane", last: "Booles", "groups" => [school])

      assert_equal 303, last_response.status
      assert_equal [store.contacts.fetch(0).id], store.group(school).members
    end
  end

  # A group that does not exist yet is named beside the contact and
  # made with it: a group created before its card is saved is one
  # left behind if that card never is.
  def test_a_group_named_beside_a_card_is_made_with_it
    with_contacts({}) do |store|
      id = upload(JANE)
      post "/import/#{id}/group", "group" => ""

      save(id, 0, first: "Jane", last: "Booles", "new" => " Clarks ")

      clarks = store.all_groups.find { it.name == "Clarks" }

      assert_equal [store.contacts.fetch(0).id], clarks.members
    end
  end

  # A save sent back to be fixed comes back with its boxes as they
  # were ticked: nothing is staged between screens, so the form is
  # the only record of them until the write.
  def test_a_refused_save_keeps_the_groups_it_was_sent_with
    with_contacts({}) do |store|
      school = store.create_group(name: "school")
      id = upload(JANE)
      get "/import/#{id}/0"

      post "/import/#{id}/0",
           "etag" => "not the etag", "first" => "Jane", "middle" => "", "last" => "Booles",
           "nickname" => "", "note" => "", "groups" => [school], "new" => "Clarks"

      assert_includes last_response.body,
                      %(<input type="checkbox" name="groups[]" value="#{school}" checked>school)
      assert_includes last_response.body,
                      %(<input type="checkbox" name="named[]" value="Clarks" checked>)
      assert_includes last_response.body, %(data-label="clarks")
      # And nothing was made for a card that is not in the book.
      refute_includes store.all_groups.map(&:name), "Clarks"
    end
  end

  # A book with three hundred groups is the same screen as a book
  # with three, and the walk opens it once per contact: the boxes are
  # filtered, and the filter is the groups dialog's own
  # (Admin::GroupFilter). Every row it is meant to see says which
  # name it matches on, and the filter itself is the way to name a
  # group this book does not have — one place rather than a list and
  # a text field under it.
  def test_the_groups_beside_a_card_are_filtered_like_the_dialogs
    with_contacts({}) do |store|
      store.create_group(name: "school")
      id = upload(JANE)

      get "/import/#{id}/0"

      assert_includes last_response.body, %(<input type="search" placeholder="Filter or add groups")
      assert_includes last_response.body, %(data-label="school")
      assert_includes last_response.body, %(<input type="checkbox" name="new" :value="filter.trim()">)
    end
  end

  # The cap the dialog got (docs/plans/2026-09-22-a-few-groups-at-a-time.md),
  # over the picker the walk opens once per contact: eight rows stand
  # shown, the ninth is marked for the filter to reach, and the button
  # counts the whole list. A group already ticked for this contact
  # takes a row from the cap rather than standing outside it.
  def test_the_groups_beside_a_card_show_a_few_at_a_time
    with_contacts({}) do |store|
      ("a".."h").each { store.create_group(name: "Group #{it}") }
      zulus = store.create_group(name: "Zulus")
      id = upload(JANE)

      get "/import/#{id}/0"

      # Alphabetical, so Zulus is the ninth and the one that goes under.
      assert_includes last_response.body, %(<label data-label="zulus" data-capped :hidden="!visible($el)">)
      assert_equal 1, last_response.body.scan("data-capped").length
      assert_includes last_response.body, "show all 9 groups"

      # Ticked on a save that came back to be fixed, so Zulus is
      # spared and Group h goes under in its place.
      post "/import/#{id}/0",
           "etag" => "not the etag", "first" => "Jane", "middle" => "", "last" => "Booles",
           "nickname" => "", "note" => "", "groups" => [zulus]

      assert_includes last_response.body, %(<label data-label="zulus" :hidden="!visible($el)">)
      assert_includes last_response.body, %(<label data-label="group h" data-capped :hidden="!visible($el)">)
      assert_equal 1, last_response.body.scan("data-capped").length
    end
  end

  def test_the_groups_beside_a_card_offer_no_such_thing_uncapped
    with_contacts({}) do |store|
      ("a".."h").each { store.create_group(name: "Group #{it}") }
      id = upload(JANE)

      get "/import/#{id}/0"

      refute_includes last_response.body, "show all"
      refute_includes last_response.body, "data-capped"
    end
  end

  # Contact by contact, so the cards do not all come in alike. The id
  # that names no group is dropped rather than carried into
  # Store#add_member, which reads a group with `sole` and would
  # answer bad input with a 500.
  def test_each_contact_comes_in_with_its_own_groups
    with_contacts({}) do |store|
      school = store.create_group(name: "school")
      id = upload(JANE + PLAIN)
      post "/import/#{id}/group", "group" => "import-20260921T031655Z"

      save(id, 0, first: "Jane", last: "Booles", "groups" => [school, "zzzz"])
      save(id, 1, first: "Sam", last: "Booles")

      assert_equal 200, last_response.status
      jane = store.contacts.find { it.name == "Jane Booles" }
      sam = store.contacts.find { it.name == "Sam Booles" }

      assert_equal [jane.id], store.group(school).members
      assert_equal ["import-20260921T031655Z", "school", ProTacts::Store::EVERYONE],
                   store.all_groups.select { it.members.include?(jane.id) }.map(&:name).sort
      assert_equal ["import-20260921T031655Z", ProTacts::Store::EVERYONE],
                   store.all_groups.select { it.members.include?(sam.id) }.map(&:name).sort
    end
  end

  # A group deleted between the tick and the Save is nothing, not a
  # 500: the ids are filtered again where they are used.
  def test_a_group_that_went_away_before_the_save_is_dropped
    with_contacts({}) do |store|
      school = store.create_group(name: "school")
      id = upload(JANE)
      post "/import/#{id}/group", "group" => ""
      get "/import/#{id}/0"
      sent = etag
      store.delete_group(school)

      post "/import/#{id}/0",
           "etag" => sent, "first" => "Jane", "middle" => "", "last" => "Booles",
           "nickname" => "", "note" => "", "groups" => [school]

      assert_equal 200, last_response.status
      assert_equal [ProTacts::Store::EVERYONE], store.all_groups.map(&:name)
    end
  end

  # The group for the lot is named before anything comes in, so one
  # import can be found — or undone — apart from the next.
  def test_the_group_for_the_lot_is_named_before_anything_comes_in
    with_contacts({}) do |_store|
      id = upload(JANE)
      follow_redirect!

      assert_includes last_response.body, %(<form action="/import/#{id}/group" method="post")
      assert_includes last_response.body, %(name="group" value="import-)

      post "/import/#{id}/group", "group" => "the Booles"

      assert_equal 303, last_response.status
      follow_redirect!

      assert_includes last_response.body, %(name="group" value="the Booles")
    end
  end

  # And not after: a rename halfway would leave what is already in
  # the book under the old name and put the rest somewhere else.
  def test_the_group_for_the_lot_is_settled_once_a_contact_is_in
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)
      post "/import/#{id}/group", "group" => "the Booles"
      save(id, 0, first: "Jane", last: "Booles")

      post "/import/#{id}/group", "group" => "somewhere else"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "Contacts from this import are in the Booles already"
      assert_includes last_response.body, "Coming in as the Booles."

      save(id, 1, first: "Sam", last: "Booles")

      refute_includes store.all_groups.map(&:name), "somewhere else"
      assert_equal store.contacts.map(&:id).sort,
                   store.all_groups.find { it.name == "the Booles" }.members.sort
    end
  end

  # Emptiable, for an import that is not worth a group of its own.
  def test_an_import_can_come_in_with_no_group_of_its_own
    with_contacts({}) do |store|
      id = upload(JANE)
      post "/import/#{id}/group", "group" => ""

      save(id, 0, first: "Jane", last: "Booles")

      assert_equal [ProTacts::Store::EVERYONE], store.all_groups.map(&:name)
    end
  end

  # Swept out from under a screen left open, or a finish submitted
  # twice: the import is gone and only the person has another copy.
  def test_finishing_an_import_that_is_gone_writes_nothing
    with_contacts({}) do |store|
      id = upload(JANE)
      save(id, 0, first: "Jane", last: "Booles")

      post "/import/#{id}/done"

      assert_includes last_response.body, "That import is no longer here."
      assert_equal 1, store.contacts.length
    end
  end

  # An id off a link is a path if nothing checks it, so only the
  # shape this server mints reaches the disk at all.
  def test_an_import_id_this_server_never_minted_reads_nothing
    with_contacts({}) do |store|
      refute ProTacts::ChangeId.minted?("notminted")

      post "/import/notminted/done"

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
