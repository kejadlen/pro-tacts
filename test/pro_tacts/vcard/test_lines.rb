require_relative "../../test_helper"

require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

class VCardLinesTest < Minitest::Test
  VCARD = ProTacts::VCard
  CARD = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Ada\r\nUID:ada\r\nEND:VCARD\r\n"

  ## the card, read once

  def test_a_card_reads_its_properties
    card = VCARD.new(CARD)

    assert_equal %w[BEGIN VERSION FN UID END], card.properties.map(&:name)
  end

  # The parse is lazy, so moving bytes never pays for reading structure.
  def test_the_parse_happens_only_when_read
    card = VCARD.new("this is not a vCard\r\n")

    assert_nil card.properties
    refute card.card?
    assert_nil card.uid
  end

  # A card is made of UTF-8 text and refuses to be made of anything
  # else — at the boundary, where the blame lands on the input rather
  # than on whatever regex would have tripped over the bytes later.
  def test_bytes_that_are_not_text_are_refused
    invalid = "FN:\xFF\r\n".dup.force_encoding(Encoding::UTF_8)

    error = assert_raises(ArgumentError) { VCARD.new(invalid) }

    assert_match "not valid UTF-8", error.message
  end

  # The envelope RFC 2426 section 4 requires, the one judgment a PUT
  # needs and the parser deliberately does not make.
  def test_card_judges_the_envelope
    assert VCARD.new(CARD).card?
    refute VCARD.new(CARD.sub("VERSION:3.0\r\n", "")).card?
    refute VCARD.new(CARD.sub("END:VCARD\r\n", "")).card?
    refute VCARD.new("BEGIN:VCARD\r\nVERSION:3.0\r\nUID:ada\r\nEND:VCARD\r\n" + "FN:Ada\r\n").card?
  end

  def test_uid_reads_without_case
    assert_equal "ada", VCARD.new(CARD).uid
    assert_nil VCARD.new(CARD.sub("UID:ada\r\n", "")).uid
  end

  ## lines

  def test_lines_yield_the_cards_lines_parsed_beside_verbatim
    lines = VCARD.new(CARD).lines

    assert_equal %w[BEGIN VERSION FN UID END], lines.map { it.property&.name }
    assert_equal CARD, lines.map(&:verbatim).join
  end

  # The split every caller that moves a property makes: the named
  # lines come back parsed beside their bytes, and what is left comes
  # back a card, byte for byte, ready to be split again.
  def test_extract_splits_a_card_without_losing_a_byte
    born = CARD.sub("UID:ada\r\n", "UID:ada\r\nBDAY:1985-04-12\r\n")
    bdays, rest = VCARD.new(born).extract("BDAY")

    assert_equal 1, bdays.length
    assert_equal "1985-04-12", bdays.fetch(0).property&.value
    assert_equal "BDAY:1985-04-12\r\n", bdays.fetch(0).verbatim
    assert_equal CARD, rest.to_s
    assert_equal "ada", rest.uid
  end

  def test_extract_of_a_property_the_card_lacks_leaves_it_whole
    bdays, rest = VCARD.new(CARD).extract("BDAY")

    assert_empty bdays
    assert_equal CARD, rest.to_s
  end

  # A fold travels with its line, byte for byte, and parses as the one
  # logical line it is.
  def test_a_fold_is_one_line
    folded = CARD.sub("UID:ada\r\n", "UID:ada\r\nBDAY:1985-04-\r\n 12\r\n")
    bday = VCARD.new(folded).lines.find { it.names?("BDAY") }

    assert_equal "1985-04-12", bday&.property&.value
    assert_equal "BDAY:1985-04-\r\n 12\r\n", bday&.verbatim
  end

  # A group prefix counts as naming the property; anything else does
  # not, and a line that will not parse is a fact about the line,
  # carried as data rather than raised.
  def test_names_judges_lines_not_properties
    grouped = CARD.sub("UID:ada\r\n", "UID:ada\r\nitem1.BDAY:1985-04-12\r\n")

    assert VCARD.new(grouped).lines.any? { it.names?("BDAY") }

    lookalike = "NOTE:BDAY:1985\r\nX-BDAY:1\r\n"

    refute VCARD.new(lookalike).lines.any? { it.names?("BDAY") }

    unparsed = VCARD.new("BDAY;=;:\r\n").lines.first

    assert_kind_of VCARD::ParseError, unparsed.error
    assert_nil unparsed.property
    assert unparsed.names?("BDAY")
    assert_equal "BDAY;=;:\r\n", unparsed.verbatim
  end

  # A broken assumption and an ordinary unreadable line are both
  # errors on a line, and telling them apart belongs here rather than
  # in whoever reports it: news about this server and ordinary bad
  # input want different handling, and neither caller should have to
  # know the parser's error taxonomy to pick.
  def test_a_line_says_whether_it_broke_an_assumption_or_merely_failed
    packed = VCARD.new("BEGIN:VCARD\r\nFN:A\rNOTE:n\r\nEND:VCARD\r\n")

    assert_equal [false, true, false], packed.lines.map { it.broke_assumption? }
    assert_match "bare CR", packed.lines.fetch(1).error&.message

    unreadable = VCARD.new("BEGIN:VCARD\r\nBDAY;=;:\r\nEND:VCARD\r\n")

    assert_kind_of VCARD::ParseError, unreadable.lines.fetch(1).error
    refute unreadable.lines.fetch(1).broke_assumption?

    refute VCARD.new(CARD).lines.any? { it.broke_assumption? }
  end

  ## insert

  def test_insert_takes_the_end_lines_terminator_for_a_bare_line
    inserted = VCARD.new(CARD).insert(["BDAY:1985-04\r\n"])

    assert_equal CARD.sub("END:VCARD\r\n", "BDAY:1985-04\r\nEND:VCARD\r\n"), inserted
    assert_operator inserted.index("BDAY"), :<, inserted.index("END:VCARD")
  end

  # A bare line takes the END line's own terminator so a card stays
  # single-convention; a terminated line keeps its own, folds and all,
  # and must not grow a second one.
  def test_insert_leaves_a_terminated_fold_its_own
    folded = "BDAY:1985-\r\n 04\r\n"

    assert_equal CARD.sub("END:VCARD\r\n", "BDAY:1985-\r\n 04\r\nEND:VCARD\r\n"),
      VCARD.new(CARD).insert([folded])
    assert_equal "BEGIN:VCARD\nEND:VCARD\n".sub("END:VCARD\n", "NOTE:x\nEND:VCARD\n"),
      VCARD.new("BEGIN:VCARD\nEND:VCARD\n").insert(["NOTE:x\n"])
  end

  def test_insert_appends_with_crlf_when_there_is_no_end
    assert_equal "not a card\r\nBDAY:1985-04\r\n",
      VCARD.new("not a card\r\n").insert(["BDAY:1985-04\r\n"])
  end

  def test_insert_with_nothing_leaves_the_card_alone
    assert_equal CARD, VCARD.new(CARD).insert([])
  end
end
