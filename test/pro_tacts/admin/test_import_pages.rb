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

  # Someone the book already has, whom JANE looks like.
  STORED_JANE = <<~CARD.gsub("\n", "\r\n")
    BEGIN:VCARD
    VERSION:3.0
    N:Booles;Jane;;;
    FN:Jane Booles
    EMAIL;type=INTERNET:jane@example.com
    UID:jane
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
  # page it came from was rendered with, and the boxes that page came
  # with sent back the way a browser sends them — a card arrives with
  # the groups it comes in under already ticked (Web#import_picker).
  # `into` opens the row folded into that contact rather than as a new
  # one (Admin::ImportTarget), and the page's own hidden fields go
  # back with the rest.
  def save(id, index, first:, last:, into: nil, **params)
    get "/import/#{id}/#{index}#{"?into=#{into}" if into}"
    post "/import/#{id}/#{index}",
         {"etag" => etag, "first" => first, "middle" => "", "last" => last,
          "nickname" => "", "note" => "",
          "groups" => ticked("groups[]"), "named" => ticked("named[]"),
          "into" => hidden("into").first.to_s, "was" => hidden("was[]")}.merge(params)
  end

  # The values of the boxes the last page rendered ticked.
  def ticked(name)
    last_response.body.scan(/name="#{Regexp.escape(name)}" value="([^"]*)" checked/).flatten
  end

  # The values of the last page's hidden fields of that name.
  def hidden(name)
    last_response.body.scan(/<input type="hidden" name="#{Regexp.escape(name)}" value="([^"]*)">/).flatten
  end

  # The group this import files its arrivals under, named when the
  # upload happens: every Save ticks it, so the name is read off the
  # staged files themselves — there is no form for it, and no screen
  # that states it apart from the boxes beside each card.
  def import_group(id)
    ProTacts::Import::Staged.saved(id).first
  end

  def test_the_screen_asks_for_a_vcf
    get "/import"

    assert_equal 200, last_response.status
    assert_includes last_response.body, %(<form action="/import" method="post" enctype="multipart/form-data")
    assert_includes last_response.body, %(<input type="file" name="vcf" accept=".vcf,text/vcard">)
  end

  # Straight into the walk: a list built from a file nobody has looked
  # at yet is a stop on the way to the same place, and it stands
  # beside every card anyway.
  def test_an_upload_opens_on_the_first_contact_having_written_nothing
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)

      assert_equal 303, last_response.status
      assert_equal "/import/#{id}/0", last_response.headers["location"]
      follow_redirect!

      assert_equal 200, last_response.status
      assert_includes last_response.body, "Jane Booles"
      assert_includes last_response.body, "Sam Booles"
      assert_includes last_response.body, %(href="/import/#{id}/1")
      assert_empty store.changes
    end
  end

  # A file with no contacts in it has no walk to walk: nothing is
  # staged, and the screen that asked for the file says why it has it
  # again — the reader's own message, the same one any file that will
  # not read gets.
  def test_a_file_with_no_contacts_in_it_comes_back_unstaged
    with_contacts({}) do |store|
      id = upload("")

      assert_equal 200, last_response.status
      assert_includes last_response.body, "this file holds no vCards"
      assert_nil id
      assert_empty store.changes
    end
  end

  # The row says what opening it would be for, in a diff's own mark: a
  # contact losing nothing does not need a visit, and wears nothing.
  def test_the_walk_marks_what_each_contact_is_losing
    with_contacts({}) do |_store|
      upload(JANE + PLAIN)
      follow_redirect!

      assert_includes last_response.body, %(<span class="type-label diff-removed">-3</span>)
      assert_equal 1, last_response.body.scan("diff-removed").length
    end
  end

  # The contacts stand beside whatever is open, rather than on a page
  # of their own: opening a row never costs your place in the list.
  # The list carries no caption — the rows are self-evidently
  # contacts — and the editor's caption row only its action, there
  # being no contact to go back to yet.
  def test_the_walk_stands_beside_the_card_being_read
    with_contacts({}) do |_store|
      id = upload(JANE + PLAIN)

      get "/import/#{id}/0"

      assert_includes last_response.body, %(<div class="walk">)
      assert_includes last_response.body, %(<nav class="record walk-list"><ul)
      assert_includes last_response.body, "Sam Booles"
      assert_includes last_response.body, %(href="/import/#{id}/1")
      # The editor's caption row carries only its action, and its
      # footer only the submit: the contact this card will become
      # does not exist to go back to.
      refute_includes last_response.body, %(href="/contacts/0")
      assert_includes last_response.body, %(<footer><button type="submit" form="contact-form")
      assert_includes last_response.body,
                      %(<a href="/import/#{id}/0" aria-current="page" data-state="unsaved">)
    end
  end

  # Everything is unsaved until its own screen says otherwise, and a
  # walk broken off overnight has to say which rows those are. The
  # rail says it on screen; the word is there for a reader that
  # cannot see one.
  def test_a_row_that_is_not_in_the_book_says_so
    with_contacts({}) do |_store|
      upload(JANE + PLAIN)
      follow_redirect!

      assert_equal 2, last_response.body.scan(%(data-state="unsaved")).length
      assert_equal 2, last_response.body.scan(%(<span class="gl-visually-hidden">not saved</span>)).length
      refute_includes last_response.body, %(<span class="type-label">not saved</span>)
    end
  end

  # Every export names the program that wrote it, and nobody is
  # going to copy that into a card: it is dropped without being
  # counted, so a file losing nothing else reads as losing nothing —
  # no row wears a mark, and the struck line on the card itself is
  # the whole of what this file is losing.
  def test_a_file_losing_only_its_exporters_name_asks_for_nothing
    with_contacts({}) do |_store|
      upload(PLAIN.sub("VERSION:3.0\r\n", "VERSION:3.0\r\nPRODID:-//Apple Inc.//macOS 15.0//EN\r\n"))
      follow_redirect!

      refute_includes last_response.body, "diff-removed"
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
      # Every line of the original, struck where it is not coming in.
      assert_includes last_response.body, "TEL;type=CELL:+1 555 0100"
      assert_includes last_response.body,
                      %(<li data-dropped><span>X-SOCIALPROFILE;type=twitter:https://twitter.com/jb</span>)
      assert_includes last_response.body, "not imported"
      # And the editor, pre-filled and pointed at the import.
      assert_includes last_response.body, %(<form action="/import/#{id}/0" method="post")
      assert_includes last_response.body, %(value="+1 555 0100")
      # The one editor in the app whose Save creates the record.
      assert_includes last_response.body, %(>Import</button>)
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
      # And the walk steps straight to the next row nobody has read,
      # the list beside it saying the row that was saved is in: it
      # opens in the walk again, and the row nobody has opened still
      # leads into it.
      assert_equal "/import/#{id}/1", last_response.headers["location"]
      follow_redirect!

      assert_includes last_response.body, %(href="/import/#{id}/0")
      assert_includes last_response.body, %(data-state="saved")
      assert_includes last_response.body, %(<span class="gl-visually-hidden">saved</span>)
      # The row's verdict now: the check landed in its circle, and no
      # count of losses — they were settled by the save.
      assert_includes last_response.body, %(<path d="m9 12 2 2 4-4">)
      refute_includes last_response.body, "diff-removed"
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
  # The row stays in the walk either way — it opens as the contact it
  # became, read beside the card it arrived as, not as a form again.
  def test_a_row_already_in_the_book_reads_in_the_walk
    with_contacts({}) do |_store|
      id = upload(JANE + PLAIN)
      save(id, 0, first: "Jane", last: "Booles")

      get "/import/#{id}/0"

      assert_equal 200, last_response.status
      assert_includes last_response.body, %(<div class="walk">)
      # The details it landed with, and the card it arrived as.
      assert_includes last_response.body, %(<dl class="detail-grid">)
      assert_includes last_response.body, "+1 555 0100"
      assert_includes last_response.body, %(data-dropped)
      # No editor and no card form to submit; the one write the look
      # back offers is the groups dialog, the contact page's own,
      # landed back on the row.
      refute_includes last_response.body, %(name="etag")
      assert_includes last_response.body, "edit groups"
      assert_includes last_response.body,
                    %(<input type="hidden" name="land" value="/import/#{id}/0">)
      # And the row's verdict is the check landed in its circle.
      assert_includes last_response.body, %(<path d="m9 12 2 2 4-4">)
      # The way into edit mode: the contact page's own edit link, in
      # the walk's caption row.
      assert_includes last_response.body,
                      %(<a href="/import/#{id}/0/edit" class="btn" data-size="sm">edit</a>)
    end
  end

  # Edit mode for a stored row: the contact's own editor over the
  # card it arrived as, posting to the row — where the amend branch
  # of the save answers — and landing back on the row's read screen.
  # A row still to do is already its editor, so its edit is the row
  # screen itself.
  def test_a_stored_row_edits_in_the_walk
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)
      save(id, 0, first: "Jane", last: "Booles")
      jane = store.contacts.fetch(0)

      get "/import/#{id}/0/edit"

      assert_equal 200, last_response.status
      assert_includes last_response.body, %(<form action="/import/#{id}/0" method="post")
      assert_includes last_response.body, %(name="etag" value="&quot;)
      assert_includes last_response.body, "Sam Booles"
      # No group boxes: the amend is #apply_edit's form, and membership
      # is the dialog's question, on the row's read screen.
      refute_includes last_response.body, %(name="groups[]")

      post "/import/#{id}/0",
           "etag" => etag, "first" => "Jane", "middle" => "", "last" => "Booles",
           "nickname" => "Jay", "note" => ""

      assert_equal "/import/#{id}/0", last_response.headers["location"]
      jane = store.contacts.fetch(0)

      assert_equal "Jay", jane.nickname

      # And an unsaved row's edit is the row screen.
      get "/import/#{id}/1/edit"

      assert_equal 303, last_response.status
      assert_equal "/import/#{id}/1", last_response.headers["location"]
    end
  end

  # Membership is asked on the look back too, with the contact page's
  # own dialog: the save lands back on the row, and the row answers
  # with the tags the write left — a look back not costing the walk
  # its place.
  def test_a_saved_rows_groups_are_edited_in_the_walk
    with_contacts({}) do |store|
      school = store.create_group(name: "school")
      id = upload(JANE + PLAIN)
      save(id, 0, first: "Jane", last: "Booles")
      jane = store.contacts.find { it.name == "Jane Booles" }
      get "/import/#{id}/0"
      joined = ticked("groups[]")

      post "/contacts/#{jane.id}/groups",
           "groups" => [school, *joined], "was" => joined, "land" => "/import/#{id}/0"

      assert_equal 303, last_response.status
      assert_equal "/import/#{id}/0", last_response.headers["location"]
      assert_equal [jane.id], store.group(school).members

      get "/import/#{id}/0"

      assert_includes last_response.body, %(href="/groups/#{school}" class="tag">)
    end
  end

  # A refused save renders the screen the dialog was opened from, the
  # notice landing on the row rather than navigating to the contact's
  # own page.
  def test_a_refused_groups_save_from_the_walk_lands_on_the_row
    with_contacts({}) do |store|
      store.create_group(name: "Clarks")
      id = upload(JANE + PLAIN)
      save(id, 0, first: "Jane", last: "Booles")
      jane = store.contacts.fetch(0)
      get "/import/#{id}/0"

      post "/contacts/#{jane.id}/groups", "named" => ["Clarks"], "land" => "/import/#{id}/0"

      assert_equal 200, last_response.status
      assert_includes last_response.body, "Another group is already named Clarks; nothing was saved."
      assert_includes last_response.body, %(<div class="walk">)
    end
  end

  # A Save pressed twice is not a second contact: the first makes
  # the contact, and the second is that row's editor's Save — the
  # amend the contact's own page would write — met by the etag guard
  # the editor always carries, the staged card the re-posted form
  # came from hashing differently than the contact now in the book.
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
      assert_equal 200, last_response.status
      assert_includes last_response.body, "This contact changed since the page loaded; nothing was saved."
    end
  end

  # Saving the last row ends the walk: there is nothing left to come
  # back to, so the import closes itself and leaves the walk for the
  # group it filed everything under, which is the list of what came
  # in and is still there tomorrow.
  def test_saving_the_last_row_ends_the_import
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)
      save(id, 0, first: "Jane", last: "Booles")
      save(id, 1, first: "Sam", last: "Booles")

      assert_equal 2, store.contacts.length
      filed = store.all_groups.find { it.name.to_s.start_with?("import-") }

      assert_equal "/groups/#{filed.id}", last_response.headers["location"]
      assert_equal store.contacts.map(&:id).sort, filed.members.sort

      jane = store.contacts.find { it.name == "Jane Booles" }

      assert_includes jane.vcard.to_s, "TEL;type=CELL:+1 555 0100"
      refute_includes jane.vcard.to_s, "X-SOCIALPROFILE"
      refute_includes jane.vcard.to_s, "X-ABRELATEDNAMES"

      follow_redirect!

      assert_includes last_response.body, %(href="/contacts/#{jane.id}")

      # And the walk is gone with it: no screen at all answers the id.
      get "/import/#{id}"

      assert_equal 404, last_response.status
    end
  end

  # Every card saved out of the group the import named leaves no group
  # to land on, so the walk ends on the book itself.
  def test_a_walk_that_filed_nothing_ends_on_the_contacts
    with_contacts({}) do |store|
      id = upload(JANE)
      save(id, 0, first: "Jane", last: "Booles", "named" => [], "groups" => [])

      assert_equal "/contacts", last_response.headers["location"]
      assert_equal 1, store.contacts.length
      assert_empty store.all_groups.map(&:name).grep(/\Aimport-/)
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

  # The group for the import is named when the file is uploaded;
  # which of this book's own groups a contact joins is asked beside
  # that contact's card, and written by the same Save as its fields.
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

      save(id, 0, first: "Jane", last: "Booles", "named" => [" Clarks "])

      clarks = store.all_groups.find { it.name == "Clarks" }

      assert_equal [store.contacts.fetch(0).id], clarks.members
    end
  end

  # The group for the import is one of the boxes beside the card, not
  # a field on a screen of its own: it is named when the upload
  # happens, ticked for every card, and shown rather than applied
  # behind the walk's back.
  def test_the_group_for_the_import_is_ticked_beside_every_card
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)
      lot = import_group(id)

      assert_match(/\Aimport-\d{8}T\d{6}Z\z/, lot)

      # On the first card it is a name, nothing having made it yet.
      get "/import/#{id}/0"

      assert_includes last_response.body, %(<input type="checkbox" name="named[]" value="#{lot}" checked>)

      save(id, 0, first: "Jane", last: "Booles")
      made = store.all_groups.find { it.name == lot }

      assert_equal [store.contacts.fetch(0).id], made.members

      # On the next one it is an ordinary box, ticked.
      get "/import/#{id}/1"

      assert_includes last_response.body,
                      %(<input type="checkbox" name="groups[]" value="#{made.id}" checked>)
    end
  end

  # And it can be unticked: an arrival that does not belong with the
  # lot is a thing the walk is for deciding.
  def test_an_arrival_can_be_kept_out_of_the_import_group
    with_contacts({}) do |store|
      id = upload(JANE)

      save(id, 0, first: "Jane", last: "Booles", "named" => [])

      assert_equal [ProTacts::Group::EVERYONE], store.all_groups.map(&:name)
    end
  end

  # Renaming it is not offered. A name typed before anything has been
  # looked at is a name for nothing, and one typed after would leave
  # what is already in the book under the old name.
  def test_the_group_for_the_import_cannot_be_renamed
    with_contacts({}) do |_store|
      id = upload(JANE)

      get "/import/#{id}/0"

      refute_includes last_response.body, %(name="group")

      post "/import/#{id}/group", "group" => "somewhere else"

      assert_equal 404, last_response.status
    end
  end

  # Everyone's book stands with the rest, ticked: a card comes in
  # going out to every phone this book syncs, and the question is
  # asked where every other group question is.
  def test_everyones_book_is_shown_beside_a_card_and_ticked
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)
      save(id, 0, first: "Jane", last: "Booles")
      everyone = store.all_groups.find { it.name == ProTacts::Group::EVERYONE }

      get "/import/#{id}/1"

      assert_includes last_response.body,
                      %(<input type="checkbox" name="groups[]" value="#{everyone.id}" checked>)

      save(id, 1, first: "Sam", last: "Booles")

      assert_equal store.contacts.map(&:id).sort, store.group(everyone.id).members.sort
    end
  end

  # And it can be unticked, like the rest: a card that is to sit on
  # the server without going out to anybody's phone.
  def test_an_arrival_can_be_kept_out_of_everyones_book
    with_contacts({}) do |store|
      id = upload(JANE + PLAIN)
      save(id, 0, first: "Jane", last: "Booles")
      everyone = store.all_groups.find { it.name == ProTacts::Group::EVERYONE }

      save(id, 1, first: "Sam", last: "Booles", "groups" => [], "named" => [])

      sam = store.contacts.find { it.name == "Sam Booles" }

      assert sam
      refute_includes store.group(everyone.id).members, sam.id
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
           "nickname" => "", "note" => "", "groups" => [school], "named" => ["Clarks"]

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
      # The offer's tick commits the name into a standing row rather
      # than leaving it on the filter, where clearing would lose it.
      assert_includes last_response.body,
                      %(<input type="checkbox" @change="if ($event.target.checked) named.push(filter.trim())">)
      assert_includes last_response.body,
                      %(<input type="checkbox" name="named[]" :value="name" checked @change="named = named.filter(n => n !== name)">)
      # A committed name is a ticked row, and a ticked row answers
      # neither the filter nor the cap: a decision the form still
      # submits is never hidden.
      assert_includes last_response.body, %(<template x-for="name in named"><label>)
      assert_includes last_response.body, %(row.querySelector('input[type=checkbox]').checked)
    end
  end

  # The cap the dialog got (docs/plans/2026-09-22-a-few-groups-at-a-time.md),
  # over the picker the walk opens once per contact: eight rows stand
  # shown, the rest are marked for the filter to reach, and the button
  # counts the whole list. A group already ticked for this contact
  # takes a row from the cap rather than standing outside it, and so
  # does the group for the import, which is ticked and not yet in the
  # list the cap reads.
  def test_the_groups_beside_a_card_show_a_few_at_a_time
    with_contacts({}) do |store|
      ("a".."h").each { store.create_group(name: "Group #{it}") }
      zulus = store.create_group(name: "Zulus")
      id = upload(JANE)

      get "/import/#{id}/0"

      # All empty, so alphabetical, and the import's own name takes
      # the eighth row, so Group h and Zulus are the two that go under.
      assert_includes last_response.body, %(<label data-label="zulus" data-capped :hidden="!visible($el)">)
      assert_equal 2, last_response.body.scan("data-capped").length
      assert_includes last_response.body, "show all 9 groups"

      # Ticked on a save that came back to be fixed — and the import's
      # own name unticked with it — so Zulus is spared and Group h
      # goes under alone.
      post "/import/#{id}/0",
           "etag" => "not the etag", "first" => "Jane", "middle" => "", "last" => "Booles",
           "nickname" => "", "note" => "", "groups" => [zulus], "named" => []

      assert_includes last_response.body, %(<label data-label="zulus" :hidden="!visible($el)">)
      assert_includes last_response.body, %(<label data-label="group h" data-capped :hidden="!visible($el)">)
      assert_equal 1, last_response.body.scan("data-capped").length
    end
  end

  # The groups most of the book is in are the ones an arrival is
  # likeliest to join, so they lead the list and stand above the cap;
  # a tie is alphabetical (Admin::ImportGroups).
  def test_the_groups_beside_a_card_are_largest_first
    with_contacts({"jane" => JANE, "sam" => PLAIN}) do |store|
      alpha = store.create_group(name: "alpha")
      charlie = store.create_group(name: "charlie")
      beta = store.create_group(name: "beta")
      zulus = store.create_group(name: "zulus")
      store.add_member(zulus, "jane")
      store.add_member(zulus, "sam")
      store.add_member(charlie, "sam")
      store.add_member(beta, "jane")
      id = upload(JANE)

      get "/import/#{id}/0"

      assert_equal [zulus, beta, charlie, alpha],
                   last_response.body.scan(/name="groups\[\]" value="([^"]+)"/).flatten
    end
  end

  def test_the_groups_beside_a_card_offer_no_such_thing_uncapped
    with_contacts({}) do |store|
      # Seven, the import's own name being the eighth row.
      ("a".."g").each { store.create_group(name: "Group #{it}") }
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
      lot = import_group(id)

      save(id, 0, first: "Jane", last: "Booles", "groups" => [school, "zzzz"], "named" => [lot])
      save(id, 1, first: "Sam", last: "Booles")

      assert_equal 303, last_response.status
      jane = store.contacts.find { it.name == "Jane Booles" }
      sam = store.contacts.find { it.name == "Sam Booles" }

      assert_equal [jane.id], store.group(school).members
      assert_equal [lot, "school", ProTacts::Group::EVERYONE],
                   store.all_groups.select { it.members.include?(jane.id) }.map(&:name).sort
      assert_equal [lot, ProTacts::Group::EVERYONE],
                   store.all_groups.select { it.members.include?(sam.id) }.map(&:name).sort
    end
  end

  # A group deleted between the tick and the Save is nothing, not a
  # 500: the ids are filtered again where they are used.
  def test_a_group_that_went_away_before_the_save_is_dropped
    with_contacts({}) do |store|
      school = store.create_group(name: "school")
      id = upload(JANE)
      get "/import/#{id}/0"
      sent = etag
      store.delete_group(school)

      post "/import/#{id}/0",
           "etag" => sent, "first" => "Jane", "middle" => "", "last" => "Booles",
           "nickname" => "", "note" => "", "groups" => [school]

      # The last row there was, so the walk ends: nothing was filed
      # under a group of its own, and the book is where it went.
      assert_equal "/contacts", last_response.headers["location"]
      assert_equal [ProTacts::Group::EVERYONE], store.all_groups.map(&:name)
    end
  end

  # Swept out from under a screen left open, or come back to after
  # its last row was saved: the import is gone and only the person
  # has another copy.
  # A card that looks like someone already in the book offers to
  # update them instead, at the top of its editor, and that offer is
  # the default: a row opened with no choice made folds into the best
  # match, and new contact is the choice made against it
  # (docs/plans/2026-09-23-update-is-the-default.md).
  def test_a_row_opens_folded_into_the_contact_it_looks_like_most
    with_contacts({"jane" => STORED_JANE}) do |_store|
      id = upload(JANE)

      get "/import/#{id}/0"

      assert_includes last_response.body, %(<div role="tablist" aria-label="Import as" data-variant="segmented">)
      assert_includes last_response.body,
                      %(<a href="/import/#{id}/0?into=" role="tab" aria-selected="false">new contact</a>)
      assert_includes last_response.body,
                      %(<a href="/import/#{id}/0?into=jane" role="tab" aria-selected="true">update Jane Booles</a>)
      assert_includes last_response.body, %(<input type="hidden" name="into" value="jane">)
      assert_includes last_response.body, %(>Update</button>)
    end
  end

  # New contact stays a choice, asked for with an empty `into` where
  # the update sides name a contact: the editor over the arriving
  # card alone.
  def test_a_new_contact_is_chosen_against_the_default
    with_contacts({"jane" => STORED_JANE}) do |_store|
      id = upload(JANE)

      get "/import/#{id}/0?into="

      assert_includes last_response.body,
                      %(<a href="/import/#{id}/0?into=" role="tab" aria-selected="true">new contact</a>)
      assert_includes last_response.body,
                      %(<a href="/import/#{id}/0?into=jane" role="tab" aria-selected="false">update Jane Booles</a>)
      refute_includes last_response.body, %(name="into")
      assert_includes last_response.body, %(>Import</button>)
    end
  end

  # A toggle with one side is not a choice.
  def test_a_card_like_nobody_in_the_book_offers_nothing_to_update
    with_contacts({"theo" => STORED_JANE.sub("Booles;Jane", "Marsh;Theo").sub("FN:Jane Booles", "FN:Theo Marsh")
                                        .sub("jane@example.com", "theo@elsewhere.org")}) do |_store|
      id = upload(JANE)

      get "/import/#{id}/0"

      refute_includes last_response.body, %(role="tablist")
    end
  end

  # The update is the contact's own editor with the card folded in:
  # the contact's name and email, the card's phone beside them, and
  # the card's lines that the contact's own stood in for struck on
  # the card as exported.
  def test_updating_opens_the_contact_with_the_card_folded_in
    with_contacts({"jane" => STORED_JANE}) do |_store|
      id = upload(JANE.sub("FN:Jane Booles", "FN:Jane B. Booles"))

      get "/import/#{id}/0?into=jane"

      assert_includes last_response.body,
                      %(<a href="/import/#{id}/0?into=jane" role="tab" aria-selected="true">update Jane Booles</a>)
      assert_includes last_response.body, %(<input type="hidden" name="into" value="jane">)
      assert_includes last_response.body, %(value="jane@example.com")
      assert_includes last_response.body, %(value="+1 555 0100")
      assert_includes last_response.body, %(<li data-dropped><span>FN:Jane B. Booles</span>)
      assert_includes last_response.body, %(>Update</button>)
    end
  end

  # Its Save edits that contact rather than adding one: the row is
  # in, it leads to the contact it was folded into, and the contact
  # joins the group the import files under beside the groups it was
  # already in.
  def test_saving_an_update_changes_the_contact_rather_than_adding_one
    with_contacts({"jane" => STORED_JANE}) do |store|
      school = store.create_group(name: "school")
      store.add_member(school, "jane")
      id = upload(JANE + PLAIN)

      save(id, 0, first: "Jane", last: "Booles", into: "jane")

      assert_equal 303, last_response.status
      assert_equal "/import/#{id}/1", last_response.headers["location"]
      assert_equal ["jane"], store.contacts.map(&:id)
      jane = store.contact("jane")

      assert_equal ["+1 555 0100"], jane.phones.map(&:value)
      assert_equal ["jane@example.com"], jane.emails.map(&:value)
      assert_equal [import_group(id), "school"], store.groups_of("jane").map(&:name).sort

      get "/import/#{id}/0"

      assert_includes last_response.body, %(<dl class="detail-grid">)
      assert_includes last_response.body, %(<a href="/import/#{id}/0" aria-current="page" data-state="saved">)
    end
  end

  # The fold is derived again at the Save, so a contact edited since
  # the page loaded refuses it the way any stale editor does.
  def test_an_update_over_a_contact_changed_since_is_refused
    with_contacts({"jane" => STORED_JANE}) do |store|
      id = upload(JANE)
      get "/import/#{id}/0?into=jane"
      sent = etag
      store.put("jane", ProTacts::VCard.new(STORED_JANE.sub("END:VCARD", "NICKNAME:Jay\r\nEND:VCARD")))

      post "/import/#{id}/0",
           "etag" => sent, "first" => "Jane", "middle" => "", "last" => "Booles",
           "nickname" => "", "note" => "", "into" => "jane"

      assert_includes last_response.body, "This card changed since the page loaded; nothing was saved."
      assert_includes last_response.body, %(<input type="hidden" name="into" value="jane">)
      assert_empty store.contact("jane").phones
    end
  end

  # And one deleted since is not quietly a new contact instead.
  def test_an_update_whose_contact_is_gone_is_refused
    with_contacts({"jane" => STORED_JANE}) do |store|
      id = upload(JANE)
      get "/import/#{id}/0?into=jane"
      sent = etag
      store.delete("jane")

      post "/import/#{id}/0",
           "etag" => sent, "first" => "Jane", "middle" => "", "last" => "Booles",
           "nickname" => "", "note" => "", "into" => "jane"

      assert_includes last_response.body, "The contact this card was updating is gone; nothing was saved."
      assert_empty store.contacts
    end
  end

  def test_a_walk_that_is_gone_says_so
    with_contacts({}) do |store|
      id = upload(JANE)
      save(id, 0, first: "Jane", last: "Booles")

      get "/import/#{id}/0"

      assert_includes last_response.body, "That import is no longer here."
      assert_equal 1, store.contacts.length
    end
  end

  # An id off a link is a path if nothing checks it, so only the
  # shape this server mints reaches the disk at all.
  def test_an_import_id_this_server_never_minted_reads_nothing
    with_contacts({}) do |store|
      refute ProTacts::ChangeId.minted?("notminted")

      get "/import/notminted/0"

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
