require_relative "../test_helper"

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

  AIDEN = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"
  APRIL_12 = ProTacts::Birthday.new(year: 1985, month: 4, day: 12)
  HOUSEHOLD_ADDRESS = "ADR;TYPE=home:;;7 Calculus Close;London;England;NW1 1AB;United Kingdom" #: String
  EDITED_ADDRESS = HOUSEHOLD_ADDRESS.sub("7 Calculus", "8 Calculus") #: String
  RESERIALIZED_ADDRESS = HOUSEHOLD_ADDRESS.sub("ADR;TYPE=home:", "ADR;type=HOME;type=pref:") #: String
  OWN_ADDRESS = "ADR:;;1 Long Road;;;;" #: String
  HOUSEHOLD = ProTacts::Group.new(
    id: "kkkk", name: "Household", label: "Household", lines: [HOUSEHOLD_ADDRESS], members: ["aiden"],
  )
  LENT = [ProTacts::Contact::Inherited.new(group: HOUSEHOLD, position: 3, line: HOUSEHOLD_ADDRESS)].freeze

  def setup
    setup_sentry
  end

  def teardown
    teardown_sentry_test
  end

  def with_lines(*lines) = AIDEN.sub("END:VCARD\r\n", lines.map { "#{it}\r\n" }.join + "END:VCARD\r\n")

  def before(stored = AIDEN, birthday: nil, inherited: [])
    ProTacts::Contact.new(id: "aiden", stored: ProTacts::VCard.new(stored), birthday:, inherited:)
  end

  # The parts with the card as its bytes, so a test compares strings.
  def decompose(bytes, before: nil)
    stored, birthday, group_edits = ProTacts::EditedContact.new(ProTacts::VCard.new(bytes), before:).decomposed
    [stored.to_s, birthday, group_edits]
  end

  def group_edit(line) = ProTacts::EditedContact::GroupEdit.new(group_id: "kkkk", position: 3, line:)

  ## The birthday

  def test_a_modeled_birthday_leaves_the_card_for_the_model
    assert_equal [AIDEN, APRIL_12, []], decompose(with_lines("BDAY:1985-04-12"))
    assert_empty sentry_messages
  end

  def test_a_card_without_a_bday_keeps_a_birthday_no_client_was_sent
    month_only = ProTacts::Birthday.new(month: 4)

    assert_equal [AIDEN, month_only, []], decompose(AIDEN, before: before(birthday: month_only))
  end

  def test_a_card_without_a_bday_drops_a_birthday_the_client_was_sent
    assert_equal [AIDEN, nil, []], decompose(AIDEN, before: before(birthday: APRIL_12))
  end

  def test_an_unrecognized_bday_stays_in_the_card_and_is_reported
    submitted = with_lines("BDAY:1985-13")

    assert_equal [submitted, nil, []], decompose(submitted)
    assert_equal ["a submitted card carried a BDAY line the model does not take"], sentry_messages
  end

  def test_several_bday_lines_stay_in_the_card_and_are_reported
    submitted = with_lines("BDAY:1985-04-12", "BDAY:1986-05-13")

    assert_equal [submitted, nil, []], decompose(submitted)
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

  ## The lent lines

  def test_a_contact_in_no_group_is_stored_as_it_arrived
    submitted = with_lines(OWN_ADDRESS)

    assert_equal [submitted, nil, []], decompose(submitted, before: before)
  end

  def test_an_untouched_lent_line_is_subtracted_and_asks_nothing
    assert_equal [AIDEN, nil, []], decompose(with_lines(HOUSEHOLD_ADDRESS), before: before(inherited: LENT))
    assert_empty sentry_messages
  end

  def test_a_reserialized_lent_line_is_still_untouched
    assert_equal [AIDEN, nil, []], decompose(with_lines(RESERIALIZED_ADDRESS), before: before(inherited: LENT))
  end

  def test_a_members_own_line_keeps_its_place_beside_a_lent_one
    own = AIDEN.sub("FN:Aiden\r\n", "#{OWN_ADDRESS}\r\nFN:Aiden\r\n")
    submitted = own.sub("END:VCARD\r\n", "#{HOUSEHOLD_ADDRESS}\r\nEND:VCARD\r\n")

    assert_equal [own, nil, []], decompose(submitted, before: before(own, inherited: LENT))
  end

  def test_an_edited_lent_line_is_an_edit_of_its_row
    assert_equal [AIDEN, nil, [group_edit(EDITED_ADDRESS)]],
                 decompose(with_lines(EDITED_ADDRESS), before: before(inherited: LENT))
  end

  def test_a_deleted_lent_line_is_a_removal_of_its_row
    assert_equal [AIDEN, nil, [group_edit(nil)]], decompose(AIDEN, before: before(inherited: LENT))
  end

  def test_two_candidates_for_one_lent_line_stay_in_the_card_and_are_reported
    submitted = with_lines(EDITED_ADDRESS, OWN_ADDRESS)

    assert_equal [submitted, nil, []], decompose(submitted, before: before(inherited: LENT))
    assert_equal 1, sentry_messages.length
  end

  def test_an_edit_no_group_may_hold_stays_in_the_card_and_is_reported
    submitted = with_lines(HOUSEHOLD_ADDRESS.sub("ADR;TYPE=home:", "item1.ADR:"), "item1.X-ABLabel:dom")

    assert_equal [submitted, nil, []], decompose(submitted, before: before(inherited: LENT))
    assert_equal 1, sentry_messages.length
  end

  def test_the_birthday_and_the_lent_lines_leave_together
    assert_equal [AIDEN, APRIL_12, []],
                 decompose(with_lines(HOUSEHOLD_ADDRESS, "BDAY:1985-04-12"), before: before(inherited: LENT))
  end

  ## The lent notes

  HOUSEHOLD_NOTE = "NOTE:Gate code 1854. The dog is friendly\\, the goose is not." #: String
  NOTE_TEXT = "Gate code 1854. The dog is friendly, the goose is not." #: String
  NEIGHBOURS = ProTacts::Group.new(
    id: "nnnn", name: "Neighbours", label: "Neighbours", lines: [HOUSEHOLD_NOTE], members: ["aiden"],
  )
  LENT_NOTE = [ProTacts::Contact::Inherited.new(group: NEIGHBOURS, position: 1, line: HOUSEHOLD_NOTE)].freeze

  def note_card(text) = AIDEN.sub("END:VCARD\r\n", "NOTE:#{ProTacts::VCard.escape(text)}\r\nEND:VCARD\r\n")

  def neighbour_edit(line) = ProTacts::EditedContact::GroupEdit.new(group_id: "nnnn", position: 1, line:)

  # What Contact#vcard composes, PUT back, stores what was stored and
  # asks nothing of the group — the round trip the strong etag answer
  # stands on, and the one a client that touched nothing makes.
  def test_the_served_note_round_trips
    stored = note_card("Own note.")
    served = note_card("Own note.\n\nShared · Neighbours:\n#{NOTE_TEXT}")

    assert_equal [stored, nil, []], decompose(served, before: before(stored, inherited: LENT_NOTE))
    assert_empty sentry_messages
  end

  # A person's whitespace between the member's text and a section is
  # not an edit: the blank line the composer writes is structure the
  # split tolerates the loss of.
  def test_whitespace_a_person_moved_is_not_an_edit
    stored = note_card("Own note.")
    served = note_card("Own note.\nShared · Neighbours:\n#{NOTE_TEXT}")

    assert_equal [stored, nil, []], decompose(served, before: before(stored, inherited: LENT_NOTE))
  end

  def test_an_edited_section_is_an_edit_of_its_row
    stored = note_card("Own note.")
    served = note_card("Own note.\n\nShared · Neighbours:\nBins go out on Tuesday.")

    assert_equal(
      [stored, nil, [neighbour_edit("NOTE:Bins go out on Tuesday.")]],
      decompose(served, before: before(stored, inherited: LENT_NOTE)),
    )
  end

  # The row receives a text value's escapes, the unit group_properties
  # holds — the same writer the editors use.
  def test_an_edited_section_escapes_what_the_row_receives
    stored = note_card("Own note.")
    served = note_card("Own note.\n\nShared · Neighbours:\nDog, friendly; goose, not.")

    assert_equal(
      [stored, nil, [neighbour_edit("NOTE:Dog\\, friendly\\; goose\\, not.")]],
      decompose(served, before: before(stored, inherited: LENT_NOTE)),
    )
  end

  # One of two sections deleted, the other and the member's own kept:
  # the present section is attributed and the absent one is the
  # removal of its row.
  DOGWALKERS = ProTacts::Group.new(
    id: "dddd", name: "Dog walkers", label: "Dog walkers", lines: ["NOTE:Sunday mornings."], members: ["aiden"],
  )

  def test_a_deleted_section_is_a_removal_of_its_row
    stored = note_card("Own note.")
    served = note_card("Own note.\n\nShared · Neighbours:\n#{NOTE_TEXT}")
    lent = [
      *LENT_NOTE,
      ProTacts::Contact::Inherited.new(group: DOGWALKERS, position: 2, line: "NOTE:Sunday mornings."),
    ]

    assert_equal(
      [stored, nil,
       [ProTacts::EditedContact::GroupEdit.new(group_id: "dddd", position: 2, line: nil)]],
      decompose(served, before: before(stored, inherited: lent)),
    )
  end

  # A member's text alone, header gone with the section, is the one
  # shape that cannot say whether the section was deleted or the
  # header was taken apart — the mangle, which propagates nothing
  # rather than guess a deletion.
  def test_a_note_left_as_the_members_own_alone_stays_whole
    served = note_card("Own note.")

    assert_equal [served, nil, []], decompose(served, before: before(served, inherited: LENT_NOTE))
    assert_equal 1, sentry_messages.length
  end

  # The cleared field: no NOTE came back at all, and every lent row
  # goes with the member's own text.
  def test_a_cleared_note_removes_every_lent_row
    assert_equal(
      [AIDEN, nil, [neighbour_edit(nil)]],
      decompose(AIDEN, before: before(note_card("Own note."), inherited: LENT_NOTE)),
    )
  end

  # A client of the two-line shape sending back what macOS truncated
  # it to: the last NOTE, which composition put last — the group's. The
  # value with no header is exactly the lent text, which reads as that
  # section present and the member's own gone.
  def test_a_truncated_note_reads_as_the_kept_section
    assert_equal(
      [AIDEN, nil, []],
      decompose(note_card(NOTE_TEXT), before: before(note_card("Own note."), inherited: LENT_NOTE)),
    )
    assert_empty sentry_messages
  end

  # Headerless text that is nothing any group lends: the mangle. The
  # whole value stays on the member, the group keeps what it lends,
  # and the arrival report says so.
  def test_an_unreadable_note_stays_whole_on_the_member_and_is_reported
    served = note_card("whatever a person typed")

    assert_equal [served, nil, []], decompose(served, before: before(note_card("Own note."), inherited: LENT_NOTE))
    assert_equal ["a submitted NOTE could not be read back into its sections; it stays on the member"],
                 sentry_messages
  end

  # The collision: the member's own text opens a line with the header,
  # and two sections claim one label.
  def test_two_sections_of_one_label_stay_whole_and_are_reported
    served = note_card("Shared · Neighbours:\nfirst\n\nShared · Neighbours:\n#{NOTE_TEXT}")

    assert_equal [served, nil, []], decompose(served, before: before(note_card("Own note."), inherited: LENT_NOTE))
    assert_equal 1, sentry_messages.length
  end

  # A nameless group's label is its id, and a group named the same
  # lends under it too: a section read under that label cannot say
  # which lent it, so nothing is attributed.
  def test_two_groups_lending_under_one_label_are_not_attributed
    same_label = ProTacts::Group.new(
      id: "Neighbours", name: nil, label: "Neighbours", lines: ["NOTE:other"], members: ["aiden"],
    )
    lent = [*LENT_NOTE, ProTacts::Contact::Inherited.new(group: same_label, position: 2, line: "NOTE:other")]
    served = note_card("Own note.\n\nShared · Neighbours:\n#{NOTE_TEXT}")

    assert_equal [served, nil, []], decompose(served, before: before(note_card("Own note."), inherited: lent))
    assert_equal ["two of a contact's groups share a label, so its submitted NOTE cannot be attributed"],
                 sentry_messages
  end

  # Foreign input, no lending: a client's two-NOTE card joins into one
  # value at the first line's position and is reported — joined rather
  # than refused, the invariant's answer to a card this server did not
  # compose.
  def test_two_own_note_lines_join_into_one_and_are_reported
    submitted = with_lines("NOTE:First", "NOTE:Second")

    assert_equal [with_lines("NOTE:First\\n\\nSecond"), nil, []], decompose(submitted, before: before)
    assert_equal ["a submitted card carried 2 NOTE lines"], sentry_messages
  end

  # The two halves at once: a lent line subtracted as a line and a
  # lent note as sections, the card that comes back holding neither.
  def test_lent_lines_and_sections_leave_together
    stored = note_card("Own note.")
    served = note_card("Own note.\n\nShared · Neighbours:\n#{NOTE_TEXT}")
      .sub("END:VCARD\r\n", "#{HOUSEHOLD_ADDRESS}\r\nEND:VCARD\r\n")

    assert_equal(
      [stored, nil, []],
      decompose(served, before: before(stored, inherited: [*LENT, *LENT_NOTE])),
    )
  end
end
