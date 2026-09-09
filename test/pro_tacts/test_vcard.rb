require_relative "../test_helper"

require "hegel"

require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

# The writer's half of the module: nothing serves through escape and
# fold yet, and a PUT or the web editor will.
class VCardTest < Minitest::Test
  include Hegel::Syntax::Methods

  ## Escaping

  # RFC 2426 section 2.4.2. escape and fold are the writer's half of this
  # module: nothing serves through them yet, and a PUT or the web editor
  # will.
  def test_the_separators_and_the_backslash_escape
    assert_equal "Smith\\, John\\; Jr.", ProTacts::VCard.escape("Smith, John; Jr.")
    assert_equal "a\\\\b", ProTacts::VCard.escape("a\\b")
  end

  # A raw line break would end the property line, so it becomes the
  # escape instead, whichever spelling it arrived in.
  def test_line_breaks_escape_rather_than_break_the_line
    assert_equal "a\\nb\\nc\\nd", ProTacts::VCard.escape("a\r\nb\rc\nd")
  end

  def test_a_line_at_the_limit_is_left_alone
    line = "NOTE:#{"x" * (ProTacts::VCard::LINE_LIMIT - 5)}"

    assert_equal ProTacts::VCard::LINE_LIMIT, line.bytesize
    assert_equal line, ProTacts::VCard.fold(line)
  end

  def test_folding_never_splits_a_character
    folded = ProTacts::VCard.fold("NOTE:#{"\u00e9" * 60}")

    folded.split("\r\n").each do |physical|
      assert_operator physical.bytesize, :<=, ProTacts::VCard::LINE_LIMIT
      assert physical.valid_encoding?
    end
  end

  ## Unescaping

  def test_unescape_reverses_escape
    assert_equal "Smith, John; Jr.", ProTacts::VCard.unescape("Smith\\, John\\; Jr.")
    assert_equal "a\\b", ProTacts::VCard.unescape("a\\\\b")
  end

  def test_unescape_reverses_the_line_break_escape
    assert_equal "a\nb\nc", ProTacts::VCard.unescape("a\\nb\\nc")
  end

  def test_escape_and_unescape_round_trip
    Hegel.test do |tc|
      value = tc.draw(text(max_size: 300))
      normalized = value.gsub(/\r\n|\r/, "\n")
      raise "unescape did not reverse escape" unless ProTacts::VCard.unescape(ProTacts::VCard.escape(value)) == normalized
    end
  end

  ## Structured values

  def test_split_components_respects_the_component_separator
    assert_equal ["", "", "12 Analytical Way", "London", "England", "NW1 1AA", "United Kingdom"],
      ProTacts::VCard.split_components(";;12 Analytical Way;London;England;NW1 1AA;United Kingdom")
  end

  def test_split_components_does_not_split_on_an_escaped_separator
    assert_equal ["Smith; Jr.", "John"], ProTacts::VCard.split_components("Smith\\; Jr.;John")
  end

  # The writer's splice: the same split with the escaping left alone,
  # so components rejoin byte for byte — unescape-then-re-escape is
  # not byte-stable (unescape leaves an unrecognized escape like "\\x"
  # alone, and escape would double its backslash).
  def test_split_raw_components_leaves_each_component_escaped
    assert_equal ["Smith\\; Jr.", "John", "a\\xb"],
      ProTacts::VCard.split_raw_components("Smith\\; Jr.;John;a\\xb")
    assert_equal "Smith\\; Jr.;John;a\\xb",
      ProTacts::VCard.split_raw_components("Smith\\; Jr.;John;a\\xb").join(";")
  end

  # The writer's line header, for a value-only edit: group, name,
  # and every parameter re-render as they read, so a save swaps the
  # value and keeps what the form never modeled. The macOS triple
  # TYPE is the case the editor exists for; an unfolded, unquoted
  # line re-renders as its own bytes.
  def test_header_of_renders_group_name_and_every_parameter
    card = ProTacts::VCard.new(
      "BEGIN:VCARD\r\n" \
      "TEL;type=CELL;type=VOICE;type=pref:+1-555-0100\r\n" \
      "item1.EMAIL;TYPE=INTERNET:ada@example.com\r\n" \
      "END:VCARD\r\n"
    )
    tel = card.properties.find { it.name.casecmp?("TEL") }
    email = card.properties.find { it.name.casecmp?("EMAIL") }

    assert_equal "TEL;type=CELL;type=VOICE;type=pref:", ProTacts::VCard.header_of(tel)
    assert_equal "item1.EMAIL;TYPE=INTERNET:", ProTacts::VCard.header_of(email)

    tel_line = card.lines.find { it.names?("TEL") }
    assert_equal tel_line.verbatim, "#{ProTacts::VCard.header_of(tel)}#{tel.value}\r\n"
  end

  # A parameter value PTEXT cannot hold — the grammar's quote-worthy
  # chars — renders in the grammar's other spelling, quoted; a value
  # that fits renders bare, either way the line the parser read.
  def test_header_of_quotes_what_ptext_cannot_hold
    bare = ProTacts::VCard::Parser::Property.new(group: nil, name: "TEL",
      parameters: [["TYPE", "cell"]], value: "+1")
    quoted = ProTacts::VCard::Parser::Property.new(group: nil, name: "TEL",
      parameters: [["X-FOO", "a:b,c"]], value: "+1")

    assert_equal "TEL;TYPE=cell:", ProTacts::VCard.header_of(bare)
    assert_equal 'TEL;X-FOO="a:b,c":', ProTacts::VCard.header_of(quoted)
  end

  ## Property tests

  def test_unfolding_reverses_folding
    Hegel.test do |tc|
      value = tc.draw(text(max_size: 300))
      line = "NOTE:#{ProTacts::VCard.escape(value)}"

      raise "unfold did not reverse fold" unless ProTacts::VCard::Parser.unfold(ProTacts::VCard.fold(line)) == line
    end
  end

  ## The card's bytes

  # Relabelling bytes is not converting them, so bytes that are not
  # UTF-8 at all never become a card: better than a store serving them
  # back as `text/vcard; charset=utf-8` while they are no such thing.
  # Relabelled first, as the route would (Web#write_card), and this
  # pins the line that catches it — the card, before any walk or any
  # bind below it could meet the bytes, and now before a store is even
  # handed one.
  def test_bytes_that_are_not_utf_8_are_not_a_card
    invalid = "BEGIN:VCARD\r\nFN:\xFF\xFE\r\nEND:VCARD\r\n".dup.force_encoding(Encoding::UTF_8)

    error = assert_raises(ArgumentError) { ProTacts::VCard.new(invalid) }

    assert_match "not valid UTF-8", error.message
  end

  ## The envelope

  # The envelope tests proper live in vcard/test_lines.rb, over the
  # card; this one covers what they do not — the names compare without
  # case.
  def test_envelope_names_compare_without_case
    lowercase = "begin:vcard\r\nversion:3.0\r\nfn:Aiden\r\nuid:aiden\r\nend:vcard\r\n"
    card = ProTacts::VCard.new(lowercase)

    assert card.card?
    assert_equal "aiden", card.uid
  end
end
