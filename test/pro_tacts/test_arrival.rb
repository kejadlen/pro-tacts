require_relative "../test_helper"

require "pro_tacts/arrival"
require "pro_tacts/birthday"
require "pro_tacts/vcard"

# The split on its own, with no database behind it: what Store#put
# applies is decided here from the card and what stood before it, so
# each branch can be read off its inputs. test_store.rb holds the same
# rules through a write, where the group rows and the served card are
# what is checked.
class ArrivalTest < Minitest::Test
  include Sentry::TestHelper
  include SentryMessages

  AIDEN = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"
  HOUSEHOLD_ADDRESS = "ADR;TYPE=home:;;7 Calculus Close;London;England;NW1 1AB;United Kingdom" #: String
  EDITED_ADDRESS = HOUSEHOLD_ADDRESS.sub("7 Calculus", "8 Calculus") #: String
  RESERIALIZED_ADDRESS = HOUSEHOLD_ADDRESS.sub("ADR;TYPE=home:", "ADR;type=HOME;type=pref:") #: String
  OWN_ADDRESS = "ADR:;;1 Long Road;;;;" #: String
  LENT = ProTacts::Arrival::Lent.new(group_id: "kkkk", position: 0, line: HOUSEHOLD_ADDRESS)

  def setup
    setup_sentry
  end

  def teardown
    teardown_sentry_test
  end

  def vcard(bytes) = ProTacts::VCard.new(bytes)

  def with_lines(*lines) = AIDEN.sub("END:VCARD\r\n", lines.map { "#{it}\r\n" }.join + "END:VCARD\r\n")

  def arrive(bytes, birthday_before: nil, stored_before: nil, lent: [])
    ProTacts::Arrival.new(
      vcard(bytes),
      birthday_before:,
      stored_before: stored_before && vcard(stored_before),
      lent:,
    )
  end

  ## The birthday

  def test_a_modeled_birthday_leaves_the_card_for_the_model
    arrival = arrive(with_lines("BDAY:1985-04-12"))

    assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12), arrival.birthday
    assert_equal AIDEN, arrival.stored.to_s
    assert_empty sentry_messages
  end

  def test_a_card_without_a_bday_keeps_a_birthday_no_client_was_sent
    month_only = ProTacts::Birthday.new(month: 4)

    assert_equal month_only, arrive(AIDEN, birthday_before: month_only).birthday
  end

  def test_a_card_without_a_bday_drops_a_birthday_the_client_was_sent
    assert_nil arrive(AIDEN, birthday_before: ProTacts::Birthday.new(year: 1985, month: 4, day: 12)).birthday
  end

  def test_an_unrecognized_bday_stays_in_the_card_and_is_reported
    submitted = with_lines("BDAY:1985-13")
    arrival = arrive(submitted)

    assert_nil arrival.birthday
    assert_equal submitted, arrival.stored.to_s
    assert_equal ["a submitted card carried a BDAY line the model does not take"], sentry_messages
  end

  def test_several_bday_lines_stay_in_the_card_and_are_reported
    submitted = with_lines("BDAY:1985-04-12", "BDAY:1986-05-13")
    arrival = arrive(submitted)

    assert_nil arrival.birthday
    assert_equal submitted, arrival.stored.to_s
    assert_equal ["a submitted card carried 2 BDAY lines"], sentry_messages
  end

  def test_a_write_dropping_a_bday_the_model_did_not_take_is_reported
    arrive(AIDEN, stored_before: with_lines("BDAY:1985-13"))

    assert_equal ["a write dropped 1 BDAY line(s) the model did not take"], sentry_messages
  end

  ## The lent lines

  def test_a_card_with_nothing_lent_is_stored_as_it_arrived
    submitted = with_lines(OWN_ADDRESS)
    arrival = arrive(submitted)

    assert_equal submitted, arrival.stored.to_s
    assert_empty arrival.edits
  end

  def test_an_untouched_lent_line_is_subtracted_and_asks_nothing
    arrival = arrive(with_lines(HOUSEHOLD_ADDRESS), stored_before: AIDEN, lent: [LENT])

    assert_equal AIDEN, arrival.stored.to_s
    assert_empty arrival.edits
    assert_empty sentry_messages
  end

  def test_a_reserialized_lent_line_is_still_untouched
    arrival = arrive(with_lines(RESERIALIZED_ADDRESS), stored_before: AIDEN, lent: [LENT])

    assert_equal AIDEN, arrival.stored.to_s
    assert_empty arrival.edits
  end

  def test_a_members_own_line_keeps_its_place_beside_a_lent_one
    own = AIDEN.sub("FN:Aiden\r\n", "#{OWN_ADDRESS}\r\nFN:Aiden\r\n")
    submitted = own.sub("END:VCARD\r\n", "#{HOUSEHOLD_ADDRESS}\r\nEND:VCARD\r\n")

    assert_equal own, arrive(submitted, stored_before: own, lent: [LENT]).stored.to_s
  end

  def test_an_edited_lent_line_is_an_edit_of_its_row
    arrival = arrive(with_lines(EDITED_ADDRESS), stored_before: AIDEN, lent: [LENT])

    assert_equal AIDEN, arrival.stored.to_s
    assert_equal [ProTacts::Arrival::GroupEdit.new(group_id: "kkkk", position: 0, line: EDITED_ADDRESS)], arrival.edits
  end

  def test_a_deleted_lent_line_is_a_removal_of_its_row
    arrival = arrive(AIDEN, stored_before: AIDEN, lent: [LENT])

    assert_equal AIDEN, arrival.stored.to_s
    assert_equal [ProTacts::Arrival::GroupEdit.new(group_id: "kkkk", position: 0, line: nil)], arrival.edits
  end

  def test_two_candidates_for_one_lent_line_stay_in_the_card_and_are_reported
    submitted = with_lines(EDITED_ADDRESS, OWN_ADDRESS)
    arrival = arrive(submitted, stored_before: AIDEN, lent: [LENT])

    assert_equal submitted, arrival.stored.to_s
    assert_empty arrival.edits
    assert_equal 1, sentry_messages.length
  end

  def test_an_edit_no_group_may_hold_stays_in_the_card_and_is_reported
    submitted = with_lines(HOUSEHOLD_ADDRESS.sub("ADR;TYPE=home:", "item1.ADR:"), "item1.X-ABLabel:dom")
    arrival = arrive(submitted, stored_before: AIDEN, lent: [LENT])

    assert_equal submitted, arrival.stored.to_s
    assert_empty arrival.edits
    assert_equal 1, sentry_messages.length
  end

  def test_the_birthday_and_the_lent_lines_leave_together
    arrival = arrive(with_lines(HOUSEHOLD_ADDRESS, "BDAY:1985-04-12"), stored_before: AIDEN, lent: [LENT])

    assert_equal AIDEN, arrival.stored.to_s
    assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12), arrival.birthday
    assert_empty arrival.edits
  end
end
