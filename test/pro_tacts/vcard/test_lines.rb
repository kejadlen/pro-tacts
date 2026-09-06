require_relative "../../test_helper"

require "digest"

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

  # A card whose bytes will not read is still a card here: it answers
  # every question from the lines that did read, and never raises. A
  # line the parser cannot read is nobody's problem to solve — the
  # bytes are served either way — so nothing above the parser is asked
  # to notice one.
  def test_a_card_that_will_not_read_answers_from_what_did
    card = VCARD.new("this is not a vCard\r\n")

    assert_empty card.properties
    refute card.card?
    assert_nil card.uid
    assert_equal ["this is not a vCard\r\n"], card.lines.map(&:verbatim)
  end

  # Only the lines that would not read drop out; the card answers from
  # the rest, envelope included.
  def test_a_card_answers_around_a_line_that_will_not_read
    card = VCARD.new(CARD.sub("FN:Ada\r\n", "FN:Ada\r\nTEL;HOME:+1-555-1234\r\n"))

    assert_equal %w[BEGIN VERSION FN UID END], card.properties.map(&:name)
    assert card.card?
    assert_equal "ada", card.uid
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

  # The line's address for a save: the SHA-256 of the verbatim bytes,
  # so identical lines digest alike — the one pair no address tells
  # apart — and any other difference is a different address.
  def test_a_lines_digest_addresses_its_bytes
    born = CARD.sub("UID:ada\r\n", "UID:ada\r\nBDAY:1985-04-12\r\n")
    bday = VCARD.new(born).lines.find { it.names?("BDAY") }

    assert_equal Digest::SHA256.hexdigest("BDAY:1985-04-12\r\n"), bday.digest
    assert_equal bday.digest, VCARD.new(born + "BDAY:1985-04-12\r\n").lines.last.digest
    refute_equal bday.digest, VCARD.new(born.sub("1985", "1986")).lines.find { it.names?("BDAY") }.digest
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

    assert_kind_of VCARD::Parser::ParseError, unparsed.error
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

    assert_kind_of VCARD::Parser::ParseError, unreadable.lines.fetch(1).error
    refute unreadable.lines.fetch(1).broke_assumption?

    refute VCARD.new(CARD).lines.any? { it.broke_assumption? }
  end

  ## replace

  # The cardinality-1 edit: the named lines swap for the new one at
  # the first match's position — not dragged to the card's end — and
  # every other line keeps its own bytes, folds and all.
  def test_replace_swaps_a_property_in_place
    card = CARD.sub("FN:Ada\r\n", "FN:Ada\r\nNICKNAME:Red\r\n")

    assert_equal card.sub("NICKNAME:Red\r\n", "NICKNAME:Crimson\r\n"),
      VCARD.new(card).replace("NICKNAME", ["NICKNAME:Crimson\r\n"]).to_s

    folded = VCARD.new(CARD.sub("UID:ada\r\n", "UID:ada\r\nTEL:+1-555-\r\n 0100\r\n"))

    assert_includes folded.replace("FN", ["FN:Grace\r\n"]).to_s, "TEL:+1-555-\r\n 0100\r\n"
  end

  # Empty lines remove the property — blank equals absent, the
  # reader's rule (see Contact#text_of) in the other direction.
  def test_replace_with_nothing_removes_the_property
    card = CARD.sub("FN:Ada\r\n", "FN:Ada\r\nNICKNAME:Red\r\n")

    assert_equal CARD, VCARD.new(card).replace("NICKNAME", []).to_s
  end

  # A card lacking the property is insert's case: the lines land
  # before END:VCARD, and nothing at all happens for an empty ask.
  def test_replace_inserts_when_the_card_lacks_the_property
    assert_equal CARD.sub("END:VCARD\r\n", "NICKNAME:Red\r\nEND:VCARD\r\n"),
      VCARD.new(CARD).replace("NICKNAME", ["NICKNAME:Red\r\n"]).to_s
    assert_equal CARD, VCARD.new(CARD).replace("NICKNAME", []).to_s
  end

  # A card that carries the property twice is cardinality-broken
  # data, and the one replacement line this writes is the repair:
  # all the named lines go, not one of them.
  def test_replace_takes_every_line_naming_the_property
    twice = CARD.sub("FN:Ada\r\n", "FN:Ada\r\nNICKNAME:Red\r\nNICKNAME:Ruby\r\n")

    assert_equal CARD.sub("FN:Ada\r\n", "FN:Ada\r\nNICKNAME:Crimson\r\n"),
      VCARD.new(twice).replace("NICKNAME", ["NICKNAME:Crimson\r\n"]).to_s
  end

  # A bare replacement line takes the replaced line's own terminator,
  # so a card the wire writes in LF stays single-convention; a
  # terminated one keeps its own.
  def test_replace_matches_the_cards_line_break_convention
    lf = "BEGIN:VCARD\nFN:Ada\nNICKNAME:Red\nEND:VCARD\n"

    assert_equal "BEGIN:VCARD\nFN:Ada\nNICKNAME:Crimson\nEND:VCARD\n",
      VCARD.new(lf).replace("NICKNAME", ["NICKNAME:Crimson"]).to_s
    assert_equal "BEGIN:VCARD\nFN:Ada\nNICKNAME:Crimson\r\nEND:VCARD\n",
      VCARD.new(lf).replace("NICKNAME", ["NICKNAME:Crimson\r\n"]).to_s
  end

  ## substitute

  # The one-line edit: the line whose bytes digest to the address
  # swaps in place, and every other line keeps its own bytes — the
  # fold on the untouched neighbor is the byte-identity claim at its
  # sharpest.
  def test_substitute_swaps_the_addressed_line_and_no_other
    card = CARD.sub("FN:Ada\r\n", "FN:Ada\r\nTEL:+1-555-0100\r\nADR:;;12 Way\r\n")
    digest = VCARD.new(card).lines.find { it.names?("TEL") }.digest

    assert_equal card.sub("TEL:+1-555-0100\r\n", "TEL:+1-555-0199\r\n"),
      VCARD.new(card).substitute(digest, ["TEL:+1-555-0199\r\n"]).to_s

    folded = CARD.sub("FN:Ada\r\n", "FN:Ada\r\nTEL:+1-555-0100\r\nADR:;;12 \r\n Way\r\n")

    assert_includes VCARD.new(folded).substitute(digest, ["TEL:+1-555-0199\r\n"]).to_s,
      "ADR:;;12 \r\n Way\r\n"
  end

  # Empty lines remove the addressed line — the blank-equals-absent
  # rule for a row the form names by digest.
  def test_substitute_with_nothing_removes_the_addressed_line
    card = CARD.sub("FN:Ada\r\n", "FN:Ada\r\nTEL:+1-555-0100\r\n")
    digest = VCARD.new(card).lines.find { it.names?("TEL") }.digest

    assert_equal CARD, VCARD.new(card).substitute(digest, []).to_s
  end

  # A digest matching no line is the caller's anomaly — the snapshot
  # guard means a miss is news, not an ordinary case — and refuses
  # loudly rather than guessing.
  def test_substitute_of_a_digest_no_line_hashes_to_raises
    card = CARD.sub("FN:Ada\r\n", "FN:Ada\r\nTEL:+1-555-0100\r\n")

    error = assert_raises(KeyError) { VCARD.new(card).substitute("0" * 64, []) }

    assert_match "no line", error.message
  end

  # A bare replacement line takes the substituted line's own
  # terminator, #replace's convention rule; a terminated one keeps
  # its own.
  def test_substitute_matches_the_cards_line_break_convention
    lf = "BEGIN:VCARD\nFN:Ada\nTEL:+1-555-0100\nEND:VCARD\n"
    digest = VCARD.new(lf).lines.find { it.names?("TEL") }.digest

    assert_equal "BEGIN:VCARD\nFN:Ada\nTEL:+1-555-0199\nEND:VCARD\n",
      VCARD.new(lf).substitute(digest, ["TEL:+1-555-0199"]).to_s
    assert_equal "BEGIN:VCARD\nFN:Ada\nTEL:+1-555-0199\r\nEND:VCARD\n",
      VCARD.new(lf).substitute(digest, ["TEL:+1-555-0199\r\n"]).to_s
  end

  # Identical bytes digest alike, which is the one pair of lines no
  # address can tell apart: the first is substituted, the second
  # keeps its bytes.
  def test_substitute_addresses_the_first_of_identical_lines
    card = CARD.sub("FN:Ada\r\n", "FN:Ada\r\nTEL:+1-555-0100\r\nTEL:+1-555-0100\r\n")
    digest = VCARD.new(card).lines.find { it.names?("TEL") }.digest

    assert_equal CARD.sub("FN:Ada\r\n", "FN:Ada\r\nTEL:+1-555-0199\r\nTEL:+1-555-0100\r\n"),
      VCARD.new(card).substitute(digest, ["TEL:+1-555-0199\r\n"]).to_s
  end

  ## insert

  def test_insert_takes_the_end_lines_terminator_for_a_bare_line
    inserted = VCARD.new(CARD).insert(["BDAY:1985-04\r\n"]).to_s

    assert_equal CARD.sub("END:VCARD\r\n", "BDAY:1985-04\r\nEND:VCARD\r\n"), inserted
    assert_operator inserted.index("BDAY"), :<, inserted.index("END:VCARD")
  end

  # A bare line takes the END line's own terminator so a card stays
  # single-convention; a terminated line keeps its own, folds and all,
  # and must not grow a second one.
  def test_insert_leaves_a_terminated_fold_its_own
    folded = "BDAY:1985-\r\n 04\r\n"

    assert_equal CARD.sub("END:VCARD\r\n", "BDAY:1985-\r\n 04\r\nEND:VCARD\r\n"),
      VCARD.new(CARD).insert([folded]).to_s
    assert_equal "BEGIN:VCARD\nEND:VCARD\n".sub("END:VCARD\n", "NOTE:x\nEND:VCARD\n"),
      VCARD.new("BEGIN:VCARD\nEND:VCARD\n").insert(["NOTE:x\n"]).to_s
  end

  def test_insert_appends_with_crlf_when_there_is_no_end
    assert_equal "not a card\r\nBDAY:1985-04\r\n",
      VCARD.new("not a card\r\n").insert(["BDAY:1985-04\r\n"]).to_s
  end

  def test_insert_with_nothing_leaves_the_card_alone
    assert_equal CARD, VCARD.new(CARD).insert([]).to_s
  end
end
