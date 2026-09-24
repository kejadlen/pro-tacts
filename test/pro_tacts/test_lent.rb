require_relative "../test_helper"

require "pro_tacts/lent"
require "pro_tacts/vcard"

# The subtraction on its own, with no store behind it: what the lines
# a member's groups lend come back as, read off the card and what
# stood before it. test_store.rb holds the same rules through
# Store#put, where the group rows and the served card are what is
# checked.
class LentTest < Minitest::Test
  include Sentry::TestHelper
  include SentryMessages

  AIDEN = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"
  HOUSEHOLD_ADDRESS = "ADR;TYPE=home:;;7 Calculus Close;London;England;NW1 1AB;United Kingdom" #: String
  EDITED_ADDRESS = HOUSEHOLD_ADDRESS.sub("7 Calculus", "8 Calculus") #: String
  RESERIALIZED_ADDRESS = HOUSEHOLD_ADDRESS.sub("ADR;TYPE=home:", "ADR;type=HOME;type=pref:") #: String
  OWN_ADDRESS = "ADR:;;1 Long Road;;;;" #: String
  HOUSEHOLD = ProTacts::Lent.new(group_id: "kkkk", position: 0, line: HOUSEHOLD_ADDRESS)

  def setup
    setup_sentry
  end

  def teardown
    teardown_sentry_test
  end

  def vcard(bytes) = ProTacts::VCard.new(bytes)

  def with_lines(*lines) = AIDEN.sub("END:VCARD\r\n", lines.map { "#{it}\r\n" }.join + "END:VCARD\r\n")

  def subtract(bytes, stored_before: AIDEN, lent: [HOUSEHOLD])
    stored, edits = ProTacts::Lent.subtract(vcard(bytes), lent, stored_before && vcard(stored_before))
    [stored.to_s, edits]
  end

  def test_a_card_with_nothing_lent_is_stored_as_it_arrived
    submitted = with_lines(OWN_ADDRESS)

    assert_equal [submitted, []], subtract(submitted, stored_before: nil, lent: [])
  end

  def test_an_untouched_lent_line_is_subtracted_and_asks_nothing
    assert_equal [AIDEN, []], subtract(with_lines(HOUSEHOLD_ADDRESS))
    assert_empty sentry_messages
  end

  def test_a_reserialized_lent_line_is_still_untouched
    assert_equal [AIDEN, []], subtract(with_lines(RESERIALIZED_ADDRESS))
  end

  def test_a_members_own_line_keeps_its_place_beside_a_lent_one
    own = AIDEN.sub("FN:Aiden\r\n", "#{OWN_ADDRESS}\r\nFN:Aiden\r\n")
    submitted = own.sub("END:VCARD\r\n", "#{HOUSEHOLD_ADDRESS}\r\nEND:VCARD\r\n")

    assert_equal [own, []], subtract(submitted, stored_before: own)
  end

  def test_an_edited_lent_line_is_an_edit_of_its_row
    edit = ProTacts::Lent::Edit.new(group_id: "kkkk", position: 0, line: EDITED_ADDRESS)

    assert_equal [AIDEN, [edit]], subtract(with_lines(EDITED_ADDRESS))
  end

  def test_a_deleted_lent_line_is_a_removal_of_its_row
    removal = ProTacts::Lent::Edit.new(group_id: "kkkk", position: 0, line: nil)

    assert_equal [AIDEN, [removal]], subtract(AIDEN)
  end

  def test_two_candidates_for_one_lent_line_stay_in_the_card_and_are_reported
    submitted = with_lines(EDITED_ADDRESS, OWN_ADDRESS)

    assert_equal [submitted, []], subtract(submitted)
    assert_equal 1, sentry_messages.length
  end

  def test_an_edit_no_group_may_hold_stays_in_the_card_and_is_reported
    submitted = with_lines(HOUSEHOLD_ADDRESS.sub("ADR;TYPE=home:", "item1.ADR:"), "item1.X-ABLabel:dom")

    assert_equal [submitted, []], subtract(submitted)
    assert_equal 1, sentry_messages.length
  end
end
