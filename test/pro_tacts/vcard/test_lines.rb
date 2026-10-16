require_relative "../../test_helper"

require "digest"

require "hegel"

require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

class VCardLinesTest < Minitest::Test
  include Hegel::Syntax::Methods

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

    assert_match "not text", error.message
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

  # Whether a line names a property is whether the parser reads it as
  # that property, wherever a fold falls — inside the group or the name
  # included, which the line's bytes alone would hide (RFC 2426
  # section 2.6).
  def test_names_agrees_with_the_parse_wherever_a_fold_falls
    token = from_regex("[A-Za-z0-9-]{1,6}", fullmatch: true)
    Hegel.test(test_cases: 1_000) do |tc|
      group = tc.draw(optional(token))
      name = tc.draw(one_of(token, sampled_from(%w[NOTE ADR BDAY TEL])))
      text = "#{"#{group}." if group}#{name}#{tc.draw(sampled_from([":", ";TYPE=home:"]))}#{tc.draw(from_regex("[a-z;:,]{0,8}", fullmatch: true))}"
      folds = tc.draw(sets(integers(min_value: 1, max_value: text.length - 1), max_size: 3)).sort.reverse
      eol = tc.draw(sampled_from(["\r\n", "\n"]))
      folded = folds.reduce(text) { |line, at| line.dup.insert(at, "#{eol}#{tc.draw(sampled_from([" ", "\t"]))}") }
      line = VCARD.new("#{folded}#{eol}").lines.fetch(0)
      asked = tc.draw(one_of(just(name), sampled_from(%w[NOTE ADR BDAY TEL]), token))

      assert_equal name.casecmp?(asked), line.names?(asked)
      assert_equal name, line.property&.name
    end
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

  # Only a physical line opening on END:VCARD anchors, and the last of
  # them: the same text inside a value or a fold's continuation is not
  # the end.
  def test_insert_anchors_on_the_last_line_that_opens_on_end
    card = "BEGIN:VCARD\r\nNOTE:END:VCARD\r\n END:VCARD\r\nend:vcard"

    assert_equal "BEGIN:VCARD\r\nNOTE:END:VCARD\r\n END:VCARD\r\nBDAY:1985-04\r\nend:vcard",
      VCARD.new(card).insert(["BDAY:1985-04"]).to_s
  end

  # Inserted lines land just inside the envelope's end: before the last
  # line that reads as END:VCARD, whatever lines only look like one, and
  # after everything where no line does.
  def test_insert_lands_before_the_end_the_parse_reads
    Hegel.test(test_cases: 1_000) do |tc|
      lines = tc.draw(arrays(sampled_from(["END:VCARDX", "end:vcard-2", "NOTE:END:VCARD", "END:VCARD", "end:vcard", "FN:Ada"]), max_size: 5))
      card = VCARD.new(["BEGIN:VCARD", *lines].map { "#{it}\r\n" }.join)
      ends = card.lines.rindex { it.property&.name&.casecmp?("END") && it.property&.value&.casecmp?("VCARD") }

      walked = card.insert(["BDAY:1985-04"]).lines.map { it.verbatim.chomp }

      assert_equal ends || card.lines.length, walked.index("BDAY:1985-04")
    end
  end

  def test_insert_with_nothing_leaves_the_card_alone
    assert_equal CARD, VCARD.new(CARD).insert([]).to_s
  end

  ## Property tests

  # The names the cards below are made of. X-TEL is the near miss a
  # name match has to tell apart from TEL, and item1.TEL the group
  # prefix it has to see through.
  NAMES = %w[FN NOTE TEL item1.TEL X-TEL EMAIL].freeze #: Array[String]

  # The names an edit asks after: BDAY is one no card below carries,
  # #insert's case.
  ASKED = %w[FN NOTE TEL EMAIL BDAY].freeze #: Array[String]

  # A card as a client might send it: an envelope around content lines
  # in either line-break convention, some folded, some that will not
  # read, and an END that may close the bytes with no terminator.
  def any_card
    composite { |dtc|
      body = dtc.draw(arrays(content_line, max_size: 8))
      last = dtc.draw(sampled_from(["\r\n", "\n", ""]))
      ProTacts::VCard.new("BEGIN:VCARD\r\nVERSION:3.0\r\n#{body.join}END:VCARD#{last}")
    }
  end

  def content_line
    composite { |dtc|
      terminator = dtc.draw(sampled_from(["\r\n", "\n"]))
      value = dtc.draw(from_regex('[^\x00\r\n]{0,12}', fullmatch: true))
      fold = dtc.draw(integers(min_value: 0, max_value: value.length))
      folded = fold.zero? ? value : value.dup.insert(fold, "#{terminator} ")
      dtc.draw(booleans(p: 0.1)) ? "garbage#{terminator}" : "#{dtc.draw(sampled_from(NAMES))}:#{folded}#{terminator}"
    }
  end

  # Lines an edit hands in, bare or terminated, each naming `name`.
  def edit_lines(name)
    line = tuples(from_regex('[^\x00\r\n]{0,12}', fullmatch: true), sampled_from(["", "\r\n", "\n"]))
    arrays(line, max_size: 3).map { |lines| lines.map { |value, terminator| "#{name}:#{value}#{terminator}" } }
  end

  def first_named(card, name) = card.lines.index { it.names?(name) }

  def reading(lines) = lines.map { [it.property, it.verbatim, it.error.class] }

  # #extract hands the remainder back already read (VCard.of), on the
  # promise that its bytes read as those same lines: no split leaves a
  # continuation stranded or a terminator missing.
  def test_an_extracted_remainder_reads_as_the_lines_it_was_made_of
    Hegel.test(test_cases: 1_000) do |tc|
      card = tc.draw(any_card)
      _, rest = card.extract(tc.draw(sampled_from(ASKED)))

      assert_equal reading(rest.lines), reading(ProTacts::VCard.new(rest.to_s).lines)
    end
  end

  # #replace touches the named lines and no others: with them taken
  # out again, the card is the one the original leaves when they are
  # taken out of it, byte for byte, and what was taken is the lines
  # handed in — present or absent before, folded or not.
  def test_replace_changes_the_named_lines_and_no_others
    Hegel.test(test_cases: 1_000) do |tc|
      card = tc.draw(any_card)
      name = tc.draw(sampled_from(ASKED))
      lines = tc.draw(edit_lines(name))
      taken, rest = card.replace(name, lines).extract(name)

      assert_equal [lines.map(&:chomp), card.extract(name).last.to_s], [taken.map(&:content), rest.to_s]
    end
  end

  # In place: the replacement starts where the first line it replaces
  # stood, not at the card's end.
  def test_replace_lands_where_the_first_named_line_stood
    Hegel.test(test_cases: 1_000) do |tc|
      card = tc.draw(any_card)
      name = tc.draw(sampled_from(NAMES.grep_v(/[-.]/)))
      tc.assume(card.lines.any? { it.names?(name) })
      lines = tc.draw(edit_lines(name).filter(&:any?))

      assert_equal first_named(card, name), first_named(card.replace(name, lines), name)
    end
  end

  # #substitute swaps the first line whose bytes the digest names and
  # no other: every line around it keeps its bytes and its place, and
  # the card's bytes read as exactly that.
  def test_substitute_swaps_the_addressed_line_and_keeps_the_rest
    Hegel.test(test_cases: 1_000) do |tc|
      card = tc.draw(any_card)
      before = card.lines.map(&:verbatim)
      addressed = card.lines.fetch(tc.draw(integers(min_value: 0, max_value: before.length - 1)))
      lines = tc.draw(edit_lines(tc.draw(sampled_from(NAMES))))

      at = before.index(addressed.verbatim)
      terminator = addressed.verbatim[/\r?\n\z/] || "\r\n"
      expected = [*before.take(at), *lines.map { it.end_with?("\n") ? it : it + terminator }, *before.drop(at + 1)]
      assert_equal expected, card.substitute(addressed.digest, lines).lines.map(&:verbatim)
    end
  end
end
