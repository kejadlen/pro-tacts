require_relative "../../test_helper"

require "hegel"

require "pro_tacts/vcard/parser"

class VCardParserTest < Minitest::Test
  include Hegel::Syntax::Methods

  def parse(card)
    ProTacts::VCard::Parser.parse(card)
  end

  # A card as it arrives: CRLF line breaks, trailing break included.
  def card(*lines)
    lines.join("\r\n") + "\r\n"
  end

  ## Content lines

  def test_every_line_comes_back_as_a_property
    properties = parse(card(
      "BEGIN:VCARD",
      "VERSION:3.0",
      "FN:Test Contact",
      "END:VCARD",
    ))

    assert_equal %w[BEGIN VERSION FN END], properties.map { it.name }
    assert_equal %w[VCARD 3.0], properties.first(2).map { it.value }
  end

  def test_a_value_may_contain_colons_and_spaces
    property = parse(card("URL:https://example.com/a:b")).first

    assert_equal "https://example.com/a:b", property.value
  end

  def test_a_value_may_be_empty
    property = parse(card("NOTE:")).first

    assert_equal "NOTE", property.name
    assert_equal "", property.value
  end

  def test_a_value_keeps_its_escaping
    property = parse(card("FN:Smith\\, John\; Jr.")).first

    assert_equal "Smith\\, John\; Jr.", property.value
  end

  def test_a_group_is_split_off_the_name
    properties = parse(card("item1.X-ABLabel:_$!<Home>!$_", "X-ABADR:us"))

    assert_equal ["item1", nil], properties.map { it.group }
    assert_equal %w[X-ABLabel X-ABADR], properties.map { it.name }
  end

  def test_blank_lines_are_skipped
    assert_equal %w[FN UID], parse("FN:A\r\n\r\nUID:b\r\n").map { it.name }
  end

  def test_a_final_line_break_is_optional
    assert_equal %w[END], parse("END:VCARD").map { it.name }
  end

  # Contacts sends CRLF, but a card that reached the store some other way
  # should not be unreadable over a line ending.
  def test_bare_line_feeds_are_accepted
    assert_equal %w[FN UID], parse("FN:A\nUID:b\n").map { it.name }
  end

  ## Parameters

  def test_a_parameter_is_a_name_and_a_value
    property = parse(card("TEL;TYPE=work:+1-555-1234")).first

    assert_equal [%w[TYPE work]], property.parameters
    assert_equal "+1-555-1234", property.value
  end

  # RFC 2426 section 3.3.1 permits both spellings, so both parse to the
  # same pairs. Contacts writes the first (see
  # docs/plans/2026-08-24-corrections-from-the-first-write.md).
  def test_a_repeated_parameter_and_a_value_list_agree
    repeated = parse(card("ADR;type=HOME;type=pref:;;1 Main St;;;;")).first
    listed = parse(card("ADR;type=HOME,pref:;;1 Main St;;;;")).first

    assert_equal [%w[type HOME], %w[type pref]], repeated.parameters
    assert_equal repeated.parameters, listed.parameters
  end

  # A quoted value is how a parameter carries the delimiters that would
  # otherwise end it.
  def test_a_quoted_parameter_value_keeps_its_delimiters
    property = parse(card('PHOTO;X-NOTE="a;b:c,d":data')).first

    assert_equal [["X-NOTE", "a;b:c,d"]], property.parameters
    assert_equal "data", property.value
  end

  def test_an_empty_parameter_value_is_allowed
    assert_equal [["TYPE", ""]], parse(card("TEL;TYPE=:+1-555-1234")).first.parameters
  end

  ## Folding

  # Unfolding takes the line break and the one whitespace character after
  # it, and nothing else: a fold falls between two octets, not between
  # two words, so a space either side of it is content.
  def test_a_folded_line_is_one_property
    property = parse(card("NOTE:supercalifragilistic", " expialidocious")).first

    assert_equal "supercalifragilisticexpialidocious", property.value
  end

  # A fold lands wherever 75 octets falls, which is not always in the
  # value: Contacts does not look at what it is splitting.
  def test_a_fold_inside_the_parameters_is_unfolded_too
    property = parse(card("TEL;TY", " PE=work:+1-555-1234")).first

    assert_equal [%w[TYPE work]], property.parameters
    assert_equal "+1-555-1234", property.value
  end

  # A line of nothing but whitespace is a fold by the letter of RFC 2426
  # section 2.6 — a line break followed by a space — so it joins the line
  # above rather than standing alone, and whatever whitespace is left
  # over becomes part of that value.
  def test_a_whitespace_only_line_folds_into_the_one_above_it
    properties = parse(card("FN:A", "   ", "UID:b"))

    assert_equal %w[FN UID], properties.map { it.name }
    assert_equal "A  ", properties.first.value
  end

  # With no line above it to fold into, the same whitespace is simply not
  # a content line. One stray line at the top of a card therefore costs
  # the whole card its index entry — it is still served, from its bytes.
  def test_a_leading_whitespace_only_line_raises
    assert_raises(ProTacts::VCard::ParseError) { parse(card("   ", "FN:A")) }
  end

  def test_a_continuation_may_start_with_a_tab
    assert_equal "abcd", parse(card("NOTE:ab", "\tcd")).first.value
  end

  ## Lines

  # lines pairs each property with the exact bytes it came from — the
  # fold travels with its line, and the verbatims join back to the card.
  def test_lines_pair_properties_with_verbatim_bytes
    card = "BEGIN:VCARD\r\nBDAY:1985-04-\r\n 12\r\nEND:VCARD\r\n"
    lines = ProTacts::VCard::Parser.lines(card)

    assert_equal %w[BEGIN BDAY END], lines.map { it.properties.first&.name }
    assert_equal "1985-04-12", lines.fetch(1).properties.first&.value
    assert_equal "BDAY:1985-04-\r\n 12\r\n", lines.fetch(1).verbatim
    assert_equal card, lines.map(&:verbatim).join
  end

  # A lone CR ends a content line inside a physical line, so one
  # logical line can read as two properties — the walk keeps both
  # beside the bytes that carried them, where the old lenient read
  # kept only the first.
  def test_a_logical_line_can_read_as_several_content_lines
    line = ProTacts::VCard::Parser.lines("FN:A\rNOTE:n\r\n").fetch(0)

    assert_equal %w[FN NOTE], line.properties.map { it.name }
    assert_nil line.error
    assert_equal %w[FN NOTE], parse("FN:A\rNOTE:n\r\n").map { it.name }
  end

  def test_a_line_that_will_not_read_carries_its_error_and_keeps_its_bytes
    line = ProTacts::VCard::Parser.lines("BDAY;=;:\r\n").fetch(0)

    assert_kind_of ProTacts::VCard::ParseError, line.error
    assert_empty line.properties
    assert_equal "BDAY;=;:\r\n", line.verbatim
  end

  # The two reads' strictness split, pinned: parse declines the whole
  # card, lines carries the same line with its error — and the raise is
  # that error, not a fresh one.
  def test_parse_raises_where_lines_carries
    card = "FN:A\r\nBDAY;=;:\r\n"
    carried = ProTacts::VCard::Parser.lines(card).fetch(1)

    error = assert_raises(ProTacts::VCard::ParseError) { parse(card) }

    assert_equal carried.error.message, error.message
  end

  # A blank line is a line — its bytes stay enumerable, so a rewrite
  # carrying lines does not drop them — while parse skips it, as the
  # grammar lets a card carry blank lines between properties.
  def test_a_blank_line_stays_a_line_but_parses_as_none
    lines = ProTacts::VCard::Parser.lines("FN:A\r\n\r\nUID:b\r\n")

    assert_equal ["FN:A\r\n", "\r\n", "UID:b\r\n"], lines.map(&:verbatim)
    assert_empty lines.fetch(1).properties
    assert_nil lines.fetch(1).error
    assert_equal %w[FN UID], parse("FN:A\r\n\r\nUID:b\r\n").map { it.name }
  end

  ## Refusals

  def test_a_line_without_a_colon_raises
    error = assert_raises(ProTacts::VCard::ParseError) { parse(card("FN")) }

    assert_match(/expected ':'/, error.message)
  end

  def test_a_line_with_no_name_raises
    assert_raises(ProTacts::VCard::ParseError) { parse(card(":value")) }
  end

  # vCard 2.1 allowed `TEL;HOME:...`; the 3.0 grammar does not, and
  # guessing which parameter was meant would invent data.
  def test_a_parameter_without_a_value_raises
    error = assert_raises(ProTacts::VCard::ParseError) { parse(card("TEL;HOME:+1-555-1234")) }

    assert_match(/HOME has no value/, error.message)
  end

  def test_bytes_that_are_not_a_card_raise
    assert_raises(ProTacts::VCard::ParseError) { parse("{\"json\": true}\r\n") }
  end

  ## Property tests

  # An independent unescaper, so a bug shared with the escaper cannot
  # hide: reverses RFC 2426 section 2.4.2.
  def unescape(text)
    text.gsub(/\\(.)/) { ::Regexp.last_match(1) == "n" ? "\n" : ::Regexp.last_match(1) }
  end

  # The renderer normalizes CRLF and CR to \n before escaping, so the
  # oracle applies the same normalization before comparing.
  def normalize(text)
    text.gsub(/\r\n|\r/, "\n")
  end

  def test_an_escaped_and_folded_value_parses_back
    Hegel.test do |tc|
      value = tc.draw(text(max_size: 300))
      line = ProTacts::VCard.fold("NOTE:#{ProTacts::VCard.escape(value)}")

      properties = ProTacts::VCard::Parser.parse("#{line}\r\n")
      raise "expected one property, got #{properties.length}" unless properties.length == 1
      raise "value did not survive" unless unescape(properties.first.value) == normalize(value)
    end
  end

  # Folding and unfolding are inverses on a rendered line, which is what
  # makes an index rebuilt from stored cards agree with what was served.
  def test_a_parameter_value_survives_a_round_trip
    token = from_regex("[A-Za-z0-9-]{1,20}", fullmatch: true)
    Hegel.test do |tc|
      name = tc.draw(token)
      values = tc.draw(arrays(token, min_size: 1, max_size: 4))
      line = "TEL#{values.map { ";#{name}=#{it}" }.join}:+1-555-1234"

      property = ProTacts::VCard::Parser.parse("#{line}\r\n").first
      raise "parameters did not survive" unless property.parameters == values.map { [name, it] }
    end
  end
end
