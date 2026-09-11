require_relative "../test_helper"

require "pro_tacts/card_diff"
require "pro_tacts/vcard"

class CardDiffTest < Minitest::Test
  AIDEN = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"

  def card(bytes) = ProTacts::VCard.new(bytes)

  def between(before, after) = ProTacts::CardDiff.between(before, after)

  def test_a_card_out_of_nothing_adds_every_line
    diff = between(nil, card(AIDEN))

    assert_equal ["BEGIN:VCARD", "VERSION:3.0", "FN:Aiden", "UID:aiden", "END:VCARD"], diff.added
    assert_empty diff.removed
  end

  def test_a_card_going_to_nothing_removes_every_line
    diff = between(card(AIDEN), nil)

    assert_empty diff.added
    assert_equal 5, diff.removed.length
  end

  def test_the_same_card_twice_is_no_change
    assert between(card(AIDEN), card(AIDEN)).empty?
  end

  def test_an_edited_line_is_a_removal_and_an_addition
    diff = between(card(AIDEN), card(AIDEN.sub("FN:Aiden", "FN:Aiden Smith")))

    assert_equal ["FN:Aiden Smith"], diff.added
    assert_equal ["FN:Aiden"], diff.removed
  end

  # macOS reorders properties on every card it touches
  # (docs/apple-contacts.md), so a diff that read position would call a
  # shuffle a rewrite of everything below the first move.
  def test_reordering_a_card_is_no_change
    shuffled = AIDEN.sub("FN:Aiden\r\nUID:aiden\r\n", "UID:aiden\r\nFN:Aiden\r\n")

    assert between(card(AIDEN), card(shuffled)).empty?
  end

  # Folding is transport (RFC 2426 section 2.6), so the two spellings
  # of one line are one line.
  def test_folding_a_line_is_no_change
    long = AIDEN.sub("FN:Aiden", "NOTE:one two")
    folded = AIDEN.sub("FN:Aiden", "NOTE:one\r\n  two")

    assert between(card(long), card(folded)).empty?
  end

  # Counted, not set-differenced: a card carrying a line twice and one
  # carrying it once are not the same card.
  def test_dropping_one_of_two_identical_lines_is_a_removal
    twice = AIDEN.sub("END:VCARD", "NOTE:Same\r\nNOTE:Same\r\nEND:VCARD")
    once = AIDEN.sub("END:VCARD", "NOTE:Same\r\nEND:VCARD")

    diff = between(card(twice), card(once))
    assert_equal ["NOTE:Same"], diff.removed
    assert_empty diff.added
  end

  def test_a_diff_survives_the_column_it_is_stored_in
    diff = between(card(AIDEN), card(AIDEN.sub("FN:Aiden", "FN:Aiden \\n Smith")))

    assert_equal diff, ProTacts::CardDiff.from_json(diff.to_json)
  end
end
