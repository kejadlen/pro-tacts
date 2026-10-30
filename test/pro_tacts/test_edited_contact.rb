require_relative "../test_helper"

require "hegel"

require "pro_tacts/birthday"
require "pro_tacts/contact"
require "pro_tacts/edited_contact"
require "pro_tacts/store"
require "pro_tacts/vcard"

# The edit on its own, with no store behind it: what Store#put writes
# is decided here from the submission and the contact before it, so
# each branch can be read off its inputs. test_store.rb holds the same
# rules through a write, where the rows and the served card are what
# is checked.
class EditedContactTest < Minitest::Test
  include Sentry::TestHelper
  include SentryMessages
  include Hegel::Syntax::Methods

  AIDEN = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"
  APRIL_12 = ProTacts::Birthday.new(year: 1985, month: 4, day: 12)
  HOUSEHOLD_ADDRESS = ProTacts::Contact::Address.new(
    po_box: "", extended: "", street: "7 Calculus Close", locality: "London", region: "England",
    postal_code: "NW1 1AB", country: "United Kingdom", label: "home"
  )
  EDITED_ADDRESS = HOUSEHOLD_ADDRESS.with(street: "8 Calculus Close")
  OWN_ADDRESS = ProTacts::Contact::Address.new(
    po_box: "", extended: "", street: "1 Long Road", locality: "", region: "", postal_code: "", country: ""
  )
  HOUSEHOLD = ProTacts::Group.new(
    id: "kkkk", name: "Household", label: "Household", addresses: [HOUSEHOLD_ADDRESS], note: nil,
    members: ["aiden"],
  )
  LENT = [ProTacts::Contact::Lent.new(
    group: HOUSEHOLD,
    addresses: [ProTacts::Contact::LentAddress.new(position: 0, address: HOUSEHOLD_ADDRESS)],
    note: nil,
  )].freeze

  def setup
    setup_sentry
  end

  def teardown
    teardown_sentry_test
  end

  def with_lines(*lines) = AIDEN.sub("END:VCARD\r\n", lines.map { "#{it}\r\n" }.join + "END:VCARD\r\n")

  # A card's line for an address, rendered as composition renders it.
  def address_line(address) = ProTacts::Contact.address_lines(ProTacts::VCard.new(AIDEN), address).join("\r\n")

  def before(stored = AIDEN, birthday: nil, addresses: [], note: nil, lent: [])
    ProTacts::ContactDetails.new(
      stored: ProTacts::VCard.new(stored), birthday:, addresses:, note:, lent:
    )
  end

  def decompose(bytes, before: nil)
    ProTacts::EditedContact.new(ProTacts::VCard.new(bytes), before:).decomposed
  end

  def address_edit(address) = ProTacts::EditedContact::AddressEdit.new(group_id: "kkkk", position: 0, address:)

  ## The birthday

  def test_a_modeled_birthday_leaves_the_card_for_the_model
    parts = decompose(with_lines("BDAY:1985-04-12"))

    assert_equal AIDEN, parts.stored.to_s
    assert_equal APRIL_12, parts.birthday
    assert_empty parts.address_edits
    assert_empty sentry_messages
  end

  def test_a_card_without_a_bday_keeps_a_birthday_no_client_was_sent
    month_only = ProTacts::Birthday.new(month: 4)
    parts = decompose(AIDEN, before: before(birthday: month_only))

    assert_equal month_only, parts.birthday
  end

  def test_a_card_without_a_bday_drops_a_birthday_the_client_was_sent
    parts = decompose(AIDEN, before: before(birthday: APRIL_12))

    assert_nil parts.birthday
  end

  def test_an_unrecognized_bday_stays_in_the_card_and_is_reported
    submitted = with_lines("BDAY:1985-13")
    parts = decompose(submitted)

    assert_equal submitted, parts.stored.to_s
    assert_nil parts.birthday
    assert_equal ["a submitted card carried a BDAY line the model does not take"], sentry_messages
  end

  def test_several_bday_lines_stay_in_the_card_and_are_reported
    submitted = with_lines("BDAY:1985-04-12", "BDAY:1986-05-13")
    parts = decompose(submitted)

    assert_equal submitted, parts.stored.to_s
    assert_equal ["a submitted card carried 2 BDAY lines"], sentry_messages
  end

  def test_a_write_dropping_a_bday_the_model_did_not_take_is_reported
    decompose(AIDEN, before: before(with_lines("BDAY:1985-13")))

    assert_equal ["a write dropped 1 BDAY line(s) the model did not take"], sentry_messages
  end

  def test_the_reports_go_once_however_often_it_is_decomposed
    edited = ProTacts::EditedContact.new(ProTacts::VCard.new(with_lines("BDAY:1985-13")), before: nil)
    2.times { edited.decomposed }

    assert_equal 1, sentry_messages.length
  end

  ## The entity's own components

  def test_a_card_without_lent_components_arrives_as_its_parts
    parts = decompose(with_lines(address_line(OWN_ADDRESS), "NOTE:Own note."))

    assert_equal AIDEN, parts.stored.to_s
    assert_equal [OWN_ADDRESS], parts.addresses
    assert_equal "Own note.", parts.note
    assert_empty sentry_messages
  end

  # The member's own rows are replaced wholesale by what came back, in
  # submission order — the rule the plan gives the PUT's unclaimed
  # addresses (docs/plans/2026-10-25-contacts-on-entities.md, "Matching
  # what comes back").
  def test_the_members_own_addresses_are_replaced_in_submission_order
    second = OWN_ADDRESS.with(street: "2 Short Road")
    parts = decompose(with_lines(address_line(second), address_line(OWN_ADDRESS)),
                      before: before(addresses: [OWN_ADDRESS]))

    assert_equal [second, OWN_ADDRESS], parts.addresses
  end

  def test_the_members_own_note_is_what_came_back
    parts = decompose(with_lines("NOTE:Edited."), before: before(note: "Own note."))

    assert_equal "Edited.", parts.note
  end

  ## The lent addresses

  def test_an_untouched_lent_address_is_subtracted_and_asks_nothing
    parts = decompose(with_lines(address_line(HOUSEHOLD_ADDRESS)), before: before(lent: LENT))

    assert_equal AIDEN, parts.stored.to_s
    assert_empty parts.addresses
    assert_empty parts.address_edits
    assert_empty sentry_messages
  end

  def test_a_reserialized_lent_address_is_still_untouched
    reserialized = "ADR;type=HOME;type=pref:;;7 Calculus Close;London;England;NW1 1AB;United Kingdom"
    parts = decompose(with_lines(reserialized), before: before(lent: LENT))

    assert_equal AIDEN, parts.stored.to_s
    assert_empty parts.address_edits
  end

  def test_a_renumbered_lent_address_is_still_untouched
    renumbered = "item3.ADR;TYPE=home:;;7 Calculus Close;London;England;NW1 1AB;United Kingdom"
    parts = decompose(with_lines(renumbered), before: before(lent: LENT))

    assert_equal AIDEN, parts.stored.to_s
    assert_empty parts.address_edits
  end

  def test_a_members_own_address_keeps_its_place_beside_a_lent_one
    submitted = with_lines(address_line(OWN_ADDRESS), address_line(HOUSEHOLD_ADDRESS))
    parts = decompose(submitted, before: before(addresses: [OWN_ADDRESS], lent: LENT))

    assert_equal [OWN_ADDRESS], parts.addresses
    assert_empty parts.address_edits
  end

  def test_an_edited_lent_address_is_an_edit_of_its_row
    parts = decompose(with_lines(address_line(EDITED_ADDRESS)), before: before(lent: LENT))

    assert_equal [address_edit(EDITED_ADDRESS)], parts.address_edits
    assert_empty parts.addresses
  end

  def test_a_deleted_lent_address_is_a_removal_of_its_row
    parts = decompose(AIDEN, before: before(lent: LENT))

    assert_equal [address_edit(nil)], parts.address_edits
  end

  # The plan's headline case for the label column: an Apple client's
  # edit that arrives under an `item` group with an X-ABLabel reaches
  # the group, where on main it stayed on the member because a group
  # could not hold a line with a property group in front
  # (docs/plans/2026-10-25-contacts-on-entities.md, "A group's address
  # carries a label like a card's").
  def test_an_edited_lent_address_under_a_label_reaches_the_group
    submitted = with_lines(
      "item1.ADR:;;8 Calculus Close;London;England;NW1 1AB;United Kingdom",
      "item1.X-ABLabel:summer house",
    )
    edited = EDITED_ADDRESS.with(label: "summer house")
    parts = decompose(submitted, before: before(lent: LENT))

    assert_equal [address_edit(edited)], parts.address_edits
    assert_empty parts.addresses
    assert_equal AIDEN, parts.stored.to_s
  end

  # A relabel is an edit like any other: the label is part of what the
  # address says.
  def test_a_relabelled_lent_address_is_an_edit
    submitted = with_lines("ADR:;;7 Calculus Close;London;England;NW1 1AB;United Kingdom")
    parts = decompose(submitted, before: before(lent: LENT))

    assert_equal [address_edit(HOUSEHOLD_ADDRESS.with(label: nil))], parts.address_edits
  end

  def test_two_candidates_for_one_lent_address_stay_on_the_member_and_are_reported
    submitted = with_lines(address_line(EDITED_ADDRESS), address_line(OWN_ADDRESS))
    parts = decompose(submitted, before: before(lent: LENT))

    assert_equal AIDEN, parts.stored.to_s.sub("FN:Aiden\r\n", "").sub("\r\n\r\n", "\r\n").sub("VERSION:3.0\r\nUID", "VERSION:3.0\r\nFN:Aiden\r\nUID")
    assert_equal [EDITED_ADDRESS, OWN_ADDRESS], parts.addresses
    assert_empty parts.address_edits
    assert_equal 1, sentry_messages.length
  end

  def test_the_birthday_and_the_lent_addresses_leave_together
    parts = decompose(with_lines(address_line(HOUSEHOLD_ADDRESS), "BDAY:1985-04-12"), before: before(lent: LENT))

    assert_equal AIDEN, parts.stored.to_s
    assert_equal APRIL_12, parts.birthday
    assert_empty parts.address_edits
  end

  ## The lent notes

  NOTE_TEXT = "Gate code 1854. The dog is friendly, the goose is not." #: String
  NEIGHBOURS = ProTacts::Group.new(
    id: "nnnn", name: "Neighbours", label: "Neighbours", addresses: [], note: NOTE_TEXT, members: ["aiden"]
  )
  LENT_NOTE = [ProTacts::Contact::Lent.new(group: NEIGHBOURS, addresses: [], note: NOTE_TEXT)].freeze

  def note_card(text) = AIDEN.sub("END:VCARD\r\n", "NOTE:#{ProTacts::VCard.escape(text)}\r\nEND:VCARD\r\n")

  def neighbour_edit(text) = ProTacts::EditedContact::NoteEdit.new(group_id: "nnnn", text:)

  # What Contact#vcard composes, PUT back, stores what was stored and
  # asks nothing of the group — the round trip the strong etag answer
  # stands on, and the one a client that touched nothing makes.
  def test_the_served_note_round_trips
    served = note_card("Own note.\n\nShared · Neighbours:\n#{NOTE_TEXT}")
    parts = decompose(served, before: before(note: "Own note.", lent: LENT_NOTE))

    assert_equal AIDEN, parts.stored.to_s
    assert_equal "Own note.", parts.note
    assert_empty parts.note_edits
    assert_empty sentry_messages
  end

  # A person's whitespace between the member's text and a section is
  # not an edit: the blank line the composer writes is structure the
  # split tolerates the loss of.
  def test_whitespace_a_person_moved_is_not_an_edit
    served = note_card("Own note.\nShared · Neighbours:\n#{NOTE_TEXT}")
    parts = decompose(served, before: before(note: "Own note.", lent: LENT_NOTE))

    assert_equal "Own note.", parts.note
    assert_empty parts.note_edits
  end

  def test_an_edited_section_is_an_edit_of_its_row
    served = note_card("Own note.\n\nShared · Neighbours:\nBins go out on Tuesday.")
    parts = decompose(served, before: before(note: "Own note.", lent: LENT_NOTE))

    assert_equal [neighbour_edit("Bins go out on Tuesday.")], parts.note_edits
    assert_equal "Own note.", parts.note
  end

  # One of two sections deleted, the other and the member's own kept:
  # the present section is attributed and the absent one is the
  # removal of its row.
  DOGWALKERS = ProTacts::Group.new(
    id: "dddd", name: "Dog walkers", label: "Dog walkers", addresses: [], note: "Sunday mornings.", members: ["aiden"]
  )

  def test_a_deleted_section_is_a_removal_of_its_row
    served = note_card("Own note.\n\nShared · Neighbours:\n#{NOTE_TEXT}")
    lent = [
      *LENT_NOTE,
      ProTacts::Contact::Lent.new(group: DOGWALKERS, addresses: [], note: "Sunday mornings."),
    ]
    parts = decompose(served, before: before(note: "Own note.", lent:))

    assert_equal [ProTacts::EditedContact::NoteEdit.new(group_id: "dddd", text: nil)], parts.note_edits
  end

  # A member's text alone, header gone with the section, is the one
  # shape that cannot say whether the section was deleted or the
  # header was taken apart — the mangle, which propagates nothing
  # rather than guess a deletion.
  def test_a_note_left_as_the_members_own_alone_stays_whole
    served = note_card("Own note.")
    parts = decompose(served, before: before(note: "Own note.", lent: LENT_NOTE))

    assert_equal AIDEN, parts.stored.to_s
    assert_equal "Own note.", parts.note
    assert_equal 1, sentry_messages.length
  end

  # The cleared field: no NOTE came back at all, and every lent row
  # goes with the member's own text.
  def test_a_cleared_note_removes_every_lent_row
    parts = decompose(AIDEN, before: before(note: "Own note.", lent: LENT_NOTE))

    assert_equal [neighbour_edit(nil)], parts.note_edits
    assert_nil parts.note
  end

  # A client of the two-line shape sending back what macOS truncated
  # it to: the last NOTE, which composition put last — the group's. The
  # value with no header is exactly the lent text, which reads as that
  # section present and the member's own gone.
  def test_a_truncated_note_reads_as_the_kept_section
    parts = decompose(note_card(NOTE_TEXT), before: before(note: "Own note.", lent: LENT_NOTE))

    assert_nil parts.note
    assert_empty parts.note_edits
    assert_empty sentry_messages
  end

  # Headerless text that is nothing any group lends: the mangle. The
  # whole value stays on the member, the group keeps what it lends,
  # and the arrival report says so.
  def test_an_unreadable_note_stays_whole_on_the_member_and_is_reported
    parts = decompose(note_card("whatever a person typed"), before: before(note: "Own note.", lent: LENT_NOTE))

    assert_equal "whatever a person typed", parts.note
    assert_equal ["a submitted NOTE could not be read back into its sections; it stays on the member"],
                 sentry_messages
  end

  # The collision: the member's own text opens a line with the header,
  # and two sections claim one label.
  def test_two_sections_of_one_label_stay_whole_and_are_reported
    served = note_card("Shared · Neighbours:\nfirst\n\nShared · Neighbours:\n#{NOTE_TEXT}")
    parts = decompose(served, before: before(note: "Own note.", lent: LENT_NOTE))

    assert_equal 1, sentry_messages.length
    assert_empty parts.note_edits
  end

  # A nameless group's label is its id, and a group named the same
  # lends under it too: a section read under that label cannot say
  # which lent it, so nothing is attributed.
  def test_two_groups_lending_under_one_label_are_not_attributed
    same_label = ProTacts::Group.new(
      id: "Neighbours", name: nil, label: "Neighbours", addresses: [], note: "other", members: ["aiden"]
    )
    lent = [
      ProTacts::Contact::Lent.new(group: same_label, addresses: [], note: "other"),
      *LENT_NOTE,
    ]
    served = note_card("Own note.\n\nShared · Neighbours:\n#{NOTE_TEXT}")
    parts = decompose(served, before: before(note: "Own note.", lent:))

    assert_equal ["two of a contact's groups share a label, so its submitted NOTE cannot be attributed"],
                 sentry_messages
    assert_empty parts.note_edits
  end

  # Foreign input, no lending: a client's two-NOTE card joins into one
  # value at the first line's position and is reported — joined rather
  # than refused, the invariant's answer to a card this server did not
  # compose.
  def test_two_own_note_lines_join_into_one_and_are_reported
    parts = decompose(with_lines("NOTE:First", "NOTE:Second"))

    assert_equal "First\n\nSecond", parts.note
    assert_equal ["a submitted card carried 2 NOTE lines"], sentry_messages
  end

  # The two halves at once: a lent address subtracted as a component
  # and a lent note as sections, the card that comes back holding
  # neither.
  def test_lent_addresses_and_sections_leave_together
    served = note_card("Own note.\n\nShared · Neighbours:\n#{NOTE_TEXT}")
      .sub("END:VCARD\r\n", "#{address_line(HOUSEHOLD_ADDRESS)}\r\nEND:VCARD\r\n")
    parts = decompose(served, before: before(note: "Own note.", lent: [*LENT, *LENT_NOTE]))

    assert_equal AIDEN, parts.stored.to_s
    assert_equal "Own note.", parts.note
    assert_empty parts.addresses
    assert_empty parts.address_edits
    assert_empty parts.note_edits
  end

  ## The round trip

  # Raw NOTE values heavy in what the round trip has to carry back:
  # escapes and the separators a client may leave bare, blank lines and
  # trailing line breaks the section split trims, and a line that reads
  # as a lent section's header.
  NOTE_PIECES = [
    "a", "b", " ", ",", "\\,", ";", "\\;", "\\\\", "\\n", "\\N",
    "\\nShared · Neighbours:\\n", "Shared · Dog walkers:",
  ].freeze #: Array[String]

  # Whatever the member's entity holds and whatever its groups lend,
  # the card Contact#vcard composes, PUT back untouched, decomposes to
  # the parts it was composed from and asks nothing of any group: the
  # no-op a syncing client makes on every pass, which must not move the
  # etag or log a change (RFC 6352 section 6.3.2.3).
  def test_a_served_card_put_back_decomposes_to_its_parts
    address = ProTacts::Contact::Address.new(
      po_box: "", extended: "", street: "1 Long Road", locality: "", region: "", postal_code: "", country: ""
    )
    Hegel.test(test_cases: 1_000) do |tc|
      note = tc.draw(optional(arrays(sampled_from(NOTE_PIECES), max_size: 6).map(&:join)))
      # A note of nothing but blank lines is no note, the split's own
      # trimming (NoteSections.trimmed) — normalize the draw to the
      # reading that comes back.
      note = nil if note.to_s.strip.empty?
      own_addresses = tc.draw(arrays(just(address), max_size: 2))
      birthday = tc.draw(optional(just(APRIL_12)))
      lent = tc.draw(sets(sampled_from([*LENT, *LENT_NOTE]), max_size: 2)).to_a
      contact = before(AIDEN, birthday:, addresses: own_addresses, note:, lent:)

      parts = decompose(contact.vcard.to_s, before: contact)

      assert_equal AIDEN, parts.stored.to_s
      assert_equal own_addresses, parts.addresses
      note.nil? ? assert_nil(parts.note) : assert_equal(note, parts.note)
      birthday.nil? ? assert_nil(parts.birthday) : assert_equal(birthday, parts.birthday)
      assert_empty parts.address_edits
      assert_empty parts.note_edits
      assert_empty sentry_messages
    end
  end
end
