require_relative "../test_helper"

require "pro_tacts/birthday"

class BirthdayTest < Minitest::Test
  # The six shapes RFC 6350 section 4.3.1 admits, one assertion per
  # shape so a failure names the one that broke.
  def test_every_admitted_shape_constructs
    ProTacts::Birthday.new(year: 1985, month: 4, day: 12)
    ProTacts::Birthday.new(year: 1985, month: 4)
    ProTacts::Birthday.new(year: 1985)
    ProTacts::Birthday.new(month: 4, day: 12)
    ProTacts::Birthday.new(month: 4)
    ProTacts::Birthday.new(day: 12)
  end

  # The two the grammar refuses: year with day but no month has no form
  # a date can take, and a birthday that is nothing at all is not one.
  def test_the_shapes_the_grammar_refuses
    error = assert_raises(ArgumentError) { ProTacts::Birthday.new(year: 1985, day: 12) }
    assert_match "not a shape", error.message

    assert_raises(ArgumentError) { ProTacts::Birthday.new }
  end

  def test_components_out_of_range_are_refused
    assert_raises(ArgumentError) { ProTacts::Birthday.new(month: 13, day: 12) }
    assert_raises(ArgumentError) { ProTacts::Birthday.new(month: 4, day: 32) }
    assert_raises(ArgumentError) { ProTacts::Birthday.new(year: 10_000, month: 4, day: 12) }
  end

  # The shape pattern matches by range, and a range admits any
  # Comparable within its bounds — so a String component is refused as a
  # shape problem. A non-Integer numeric would pass; no producer can
  # make one (SQLite integer columns and #to_i are Integers), which the
  # constructor's comment records as the boundary of the check.
  def test_components_that_are_not_integers_are_refused
    assert_raises(ArgumentError) { ProTacts::Birthday.new(year: "1985", month: 4, day: 12) }
    assert_raises(ArgumentError) { ProTacts::Birthday.new(year: 1985, month: "4", day: 12) }
  end

  def test_the_wire_forms
    assert_equal "BDAY:1985-04-12", ProTacts::Birthday.new(year: 1985, month: 4, day: 12).to_line
    assert_equal "BDAY;X-APPLE-OMIT-YEAR=1604:1604-04-12", ProTacts::Birthday.new(month: 4, day: 12).to_line
  end

  # The four shapes no client has been verified to accept reach no wire;
  # this is the set the deletion rule treats as invisible.
  def test_the_shapes_without_a_verified_spelling_serve_nothing
    [ProTacts::Birthday.new(year: 1985, month: 4), ProTacts::Birthday.new(year: 1985),
      ProTacts::Birthday.new(month: 4), ProTacts::Birthday.new(day: 12)].each do |birthday|
      assert_nil birthday.to_line
      refute birthday.served?
    end
  end

  def test_the_served_shapes
    [ProTacts::Birthday.new(year: 1985, month: 4, day: 12), ProTacts::Birthday.new(month: 4, day: 12)].each do |birthday|
      assert birthday.served?
    end
  end

  ## subtract

  CARD = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Ada\r\nUID:ada\r\nEND:VCARD\r\n"

  def test_a_full_date_moves_into_the_model_and_out_of_the_card
    split = ProTacts::Birthday.subtract(CARD.sub("FN:Ada\r\n", "FN:Ada\r\nBDAY:1985-04-12\r\n"))

    assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12), split.birthday
    assert_equal CARD, split.card
    refute split.bday_kept
  end

  # docs/macos-contacts.md, "Birthdays without a year": the verified
  # Apple form, with 1604 standing in for the year in both halves.
  def test_the_apple_no_year_form_moves_into_the_model
    split = ProTacts::Birthday.subtract(CARD.sub("FN:Ada\r\n", "FN:Ada\r\nBDAY;X-APPLE-OMIT-YEAR=1604:1604-04-12\r\n"))

    assert_equal ProTacts::Birthday.new(month: 4, day: 12), split.birthday
    assert_equal CARD, split.card
  end

  # RFC 2426 section 3.1.5 lets BDAY carry a date and time; the time is
  # the one thing ingest deliberately loses, because a birthday is a
  # date — the design record's decision, not an oversight.
  def test_a_date_time_loses_its_time_on_the_way_in
    ["BDAY:1985-04-12T23:10:00Z", "BDAY:1985-04-12T08:30:00-06:00"].each do |line|
      split = ProTacts::Birthday.subtract(CARD.sub("FN:Ada\r\n", "FN:Ada\r\n#{line}\r\n"))

      assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12), split.birthday, line
      assert_equal CARD, split.card, line
    end
  end

  def test_names_and_parameters_match_without_case
    split = ProTacts::Birthday.subtract(CARD.sub("FN:Ada\r\n", "FN:Ada\r\nbday;x-apple-omit-year=1604:1604-04-12\r\n"))

    assert_equal ProTacts::Birthday.new(month: 4, day: 12), split.birthday
  end

  def test_a_folded_bday_is_one_property
    split = ProTacts::Birthday.subtract(CARD.sub("UID:ada\r\n", "BDAY:1985-04-\r\n 12\r\nUID:ada\r\n"))

    assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12), split.birthday
    assert_equal CARD, split.card
  end

  # Everything the model cannot recompose stays in the card byte for
  # byte (RFC 6352 section 6.3.2.2), and the model is emptied so compose
  # never adds a second BDAY beside it. The probe cards ride on this.
  def test_the_unmodeled_spellings_stay_verbatim
    unmodeled = [
      "BDAY:--0412",       # vCard 4.0 basic, month-day
      "BDAY:--04-12",      # vCard 4.0 extended, month-day
      "BDAY:1985",         # year alone
      "BDAY:1985-04",      # year and month
      "BDAY:---12",        # day alone
      "BDAY:19850412",     # undashed full date, legal 3.0
      "BDAY:1985-4-12",    # unpadded, not the grammar's shape
      "BDAY;VALUE=DATE:1985-04-12",
      "BDAY;X-APPLE-OMIT-YEAR=1605:1605-04-12", # a foreign sentinel
      "BDAY;X-APPLE-OMIT-YEAR=1604;X-OTHER=1:1604-04-12", # parameters compose would drop
      "item1.BDAY:1985-04-12", # a grouped property's label pairing belongs to the card
      "BDAY:",             # nothing to read
      "BDAY:1985-13-40",   # components out of range
    ]

    unmodeled.each do |line|
      card = CARD.sub("FN:Ada\r\n", "FN:Ada\r\n#{line}\r\n")
      split = ProTacts::Birthday.subtract(card)

      assert_nil split.birthday, line
      assert_equal card, split.card, line
      assert split.bday_kept, line
    end
  end

  def test_more_than_one_bday_stays_verbatim
    card = CARD.sub("FN:Ada\r\n", "FN:Ada\r\nBDAY:1985-04-12\r\nBDAY:1986-04-12\r\n")
    split = ProTacts::Birthday.subtract(card)

    assert_nil split.birthday
    assert_equal card, split.card
    assert split.bday_kept
  end

  def test_a_card_without_a_bday_is_untouched
    split = ProTacts::Birthday.subtract(CARD)

    assert_nil split.birthday
    assert_equal CARD, split.card
    refute split.bday_kept
  end

  # Bytes that are not the UTF-8 the store's contract promises are not
  # this model's business: they pass through so the bind that enforces
  # the contract is what refuses them.
  def test_bytes_that_are_not_utf_8_pass_through_unparsed
    invalid = "BDAY:\xFF\xFE\r\n".dup.force_encoding(Encoding::UTF_8)
    split = ProTacts::Birthday.subtract(invalid)

    assert_equal invalid, split.card
    assert_nil split.birthday
    refute split.bday_kept
  end

  ## compose

  def test_compose_puts_the_birthday_before_the_end
    composed = ProTacts::Birthday.compose(CARD, ProTacts::Birthday.new(year: 1985, month: 4, day: 12))

    assert_equal CARD.sub("END:VCARD\r\n", "BDAY:1985-04-12\r\nEND:VCARD\r\n"), composed
  end

  def test_compose_takes_the_end_lines_own_terminator
    card = "BEGIN:VCARD\nUID:ada\nEND:VCARD\n"
    composed = ProTacts::Birthday.compose(card, ProTacts::Birthday.new(month: 4, day: 12))

    assert_equal "BEGIN:VCARD\nUID:ada\nBDAY;X-APPLE-OMIT-YEAR=1604:1604-04-12\nEND:VCARD\n", composed
  end

  def test_compose_leaves_a_card_alone_when_there_is_nothing_to_say
    assert_equal CARD, ProTacts::Birthday.compose(CARD, nil)
    assert_equal CARD, ProTacts::Birthday.compose(CARD, ProTacts::Birthday.new(year: 1985))
  end

  def test_compose_appends_when_there_is_no_end_to_anchor_to
    assert_equal "not a card\r\nBDAY:1985-04-12\r\n",
      ProTacts::Birthday.compose("not a card\r\n", ProTacts::Birthday.new(year: 1985, month: 4, day: 12))
  end

  ## the pair of them

  # subtract and compose are inverses on the model and on every line
  # but the BDAY's own place in the card, which compose chooses.
  def test_compose_undoes_subtract
    birthday = ProTacts::Birthday.new(month: 4, day: 12)
    split = ProTacts::Birthday.subtract(CARD.sub("END:VCARD\r\n", "BDAY;X-APPLE-OMIT-YEAR=1604:1604-04-12\r\nEND:VCARD\r\n"))

    assert_equal birthday, split.birthday
    assert_equal birthday, ProTacts::Birthday.subtract(ProTacts::Birthday.compose(split.card, birthday)).birthday
  end
end
