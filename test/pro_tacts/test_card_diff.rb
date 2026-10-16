require_relative "../test_helper"

require "hegel"

require "pro_tacts/card_diff"
require "pro_tacts/vcard"

class CardDiffTest < Minitest::Test
  include Hegel::Syntax::Methods

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

  ## Property tests

  # A few lines drawn often, so two cards share some and a card
  # carries some twice, beside lines drawn fresh.
  COMMON = ["FN:Ada", "NOTE:one two", "TEL:+1-555-0100", "item1.EMAIL:ada@example.com"].freeze #: Array[String]

  def content = one_of(sampled_from(COMMON), from_regex('[A-Z]{1,4}:[^\r\n]{0,10}', fullmatch: true))

  def contents = arrays(content, max_size: 8)

  # The lines as a client might spell them on the wire: each with its
  # own terminator and maybe a fold, in an order of the draw's.
  def card_of(tc, lines)
    order = tc.draw(arrays(integers, min_size: lines.length, max_size: lines.length))
    spelled = lines.zip(order).sort_by(&:last).map { |line, _|
      terminator = tc.draw(sampled_from(["\r\n", "\n"]))
      fold = tc.draw(integers(min_value: 0, max_value: line.length - 1))
      "#{fold.zero? ? line : line.dup.insert(fold, "#{terminator} ")}#{terminator}"
    }
    card(spelled.join)
  end

  # What a diff is over: the card's logical lines, unfolded and with
  # no terminator — the unit the class comment names.
  def content_of(vcard) = vcard.lines.map(&:content).reject(&:empty?)

  # The diff is the write: the card before, with what it removed taken
  # off and what it added put on, carries the lines of the card after.
  def test_a_diff_takes_the_card_before_to_the_card_after
    Hegel.test(test_cases: 1_000) do |tc|
      before = card_of(tc, tc.draw(contents))
      after = card_of(tc, tc.draw(contents))
      diff = between(before, after)

      remaining = content_of(before).tally
      diff.removed.each { remaining[it] -= 1 }
      diff.added.each { remaining[it] = remaining.fetch(it, 0) + 1 }
      assert_equal content_of(after).tally, remaining.reject { |_, count| count.zero? }
    end
  end

  # Lines both cards carry cancel, so no line is both added and
  # removed: a write records what moved and nothing that stood still.
  def test_no_line_is_both_added_and_removed
    Hegel.test(test_cases: 1_000) do |tc|
      diff = between(card_of(tc, tc.draw(contents)), card_of(tc, tc.draw(contents)))

      assert_empty diff.added & diff.removed
    end
  end

  # The diff back is the diff forward turned around.
  def test_the_diff_back_is_the_diff_forward_reversed
    Hegel.test(test_cases: 1_000) do |tc|
      before = card_of(tc, tc.draw(contents))
      after = card_of(tc, tc.draw(contents))

      forward = between(before, after)
      assert_equal [forward.removed, forward.added], between(after, before).deconstruct
    end
  end

  # A card's own lines spelled again — reordered, refolded, its line
  # breaks swapped — is no change: the shuffle macOS makes of every
  # card it touches (docs/apple-contacts.md) and the folds the wire
  # moves (RFC 2426 section 2.6).
  def test_the_same_lines_spelled_again_are_no_change
    Hegel.test(test_cases: 1_000) do |tc|
      lines = tc.draw(contents)

      assert_predicate between(card_of(tc, lines), card_of(tc, lines)), :empty?
    end
  end

  # The group log's path and the card's are the same difference by
  # the same code (CardDiff.between_lines), so over the same lines
  # they agree.
  def test_a_groups_lines_diff_as_a_cards_would
    Hegel.test(test_cases: 1_000) do |tc|
      before = card_of(tc, tc.draw(contents))
      after = card_of(tc, tc.draw(contents))

      assert_equal between(before, after), ProTacts::CardDiff.between_lines(content_of(before), content_of(after))
    end
  end

  # The stored spelling holds any line byte for byte, whatever it
  # carries.
  def test_any_diff_survives_the_column_it_is_stored_in
    Hegel.test(test_cases: 1_000) do |tc|
      diff = ProTacts::CardDiff.new(added: tc.draw(arrays(text(max_size: 20))), removed: tc.draw(arrays(text(max_size: 20))))

      assert_equal diff, ProTacts::CardDiff.from_json(diff.to_json)
    end
  end
end
