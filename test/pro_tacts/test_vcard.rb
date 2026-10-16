require_relative "../test_helper"

require "hegel"

require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

# The writer's half of the module: escape and header_of, which the web
# editor's saves are rebuilt through (Admin::CardForm).
class VCardTest < Minitest::Test
  include Hegel::Syntax::Methods

  ## Escaping

  # RFC 2426 section 2.4.2.
  def test_the_separators_and_the_backslash_escape
    assert_equal "Smith\\, John\\; Jr.", ProTacts::VCard.escape("Smith, John; Jr.")
    assert_equal "a\\\\b", ProTacts::VCard.escape("a\\b")
  end

  # A raw line break would end the property line, so it becomes the
  # escape instead, whichever spelling it arrived in.
  def test_line_breaks_escape_rather_than_break_the_line
    assert_equal "a\\nb\\nc\\nd", ProTacts::VCard.escape("a\r\nb\rc\nd")
  end

  ## Unescaping

  def test_unescape_reverses_escape
    assert_equal "Smith, John; Jr.", ProTacts::VCard.unescape("Smith\\, John\\; Jr.")
    assert_equal "a\\b", ProTacts::VCard.unescape("a\\\\b")
  end

  def test_unescape_reverses_the_line_break_escape
    assert_equal "a\nb\nc", ProTacts::VCard.unescape("a\\nb\\nc")
  end

  # Apple wraps its own label vocabulary and nobody else's does; a
  # person's own label passes through untouched.
  def test_unwrap_takes_apples_own_label_wrapping_off
    assert_equal "Spouse", ProTacts::VCard.unwrap("_$!<Spouse>!$_")
    assert_equal "Google Voice", ProTacts::VCard.unwrap("Google Voice")
    assert_equal "_$!<Spouse", ProTacts::VCard.unwrap("_$!<Spouse")
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

  # The backslash before this ";" is the second half of an escaped
  # backslash, so the separator is a separator: the case the property
  # below shrank to.
  def test_split_components_ends_a_component_at_an_escaped_backslash
    assert_equal ["C:\\", "John"], ProTacts::VCard.split_components("C:\\\\;John")
  end

  # The third component is the case the byte-stability argument on
  # VCard.split_raw_components turns on: an escape neither half of the
  # pair recognizes, which a round trip through them would corrupt.
  def test_split_raw_components_leaves_each_component_escaped
    assert_equal ["Smith\\; Jr.", "John", "a\\xb"],
      ProTacts::VCard.split_raw_components("Smith\\; Jr.;John;a\\xb")
    assert_equal "Smith\\; Jr.;John;a\\xb",
      ProTacts::VCard.split_raw_components("Smith\\; Jr.;John;a\\xb").join(";")
  end

  # Text heavy in the characters the escapes give meaning to, which a
  # draw from all of Unicode reaches too rarely to land beside one
  # another: a separator after a backslash, a backslash at a
  # component's end, an escape neither half recognizes.
  ESCAPEY = %W[; , \\ \\; \\\\ \\n \\x \n \r\n a].freeze #: Array[String]

  def escapey_text = one_of(text(max_size: 20), arrays(sampled_from(ESCAPEY), max_size: 8).map(&:join))

  # The two halves of a structured value agree: components escaped and
  # joined by the writer read back, through the reader's split, as the
  # components they were — whatever text they hold, a trailing
  # backslash included. One empty component is the empty value, the
  # same bytes as none, and reads as none; every caller pads to the
  # positions it splices (Admin::CardForm).
  def test_escaped_components_split_back_as_they_were
    Hegel.test(test_cases: 1_000) do |tc|
      components = tc.draw(arrays(escapey_text, min_size: 1, max_size: 7))
      value = components.map { ProTacts::VCard.escape(it) }.join(";")
      expected = value.empty? ? [] : components.map { it.gsub(/\r\n|\r/, "\n") }

      assert_equal expected, ProTacts::VCard.split_components(value)
    end
  end

  # The byte-stability a splice relies on: any value, escapes the
  # writer never makes included, joins back from its raw components as
  # the bytes it was.
  def test_raw_components_join_back_byte_for_byte
    Hegel.test(test_cases: 1_000) do |tc|
      value = tc.draw(escapey_text)

      assert_equal value, ProTacts::VCard.split_raw_components(value).join(";")
    end
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

  # Whatever a parse could have read, header_of renders a header that
  # reads back as it: group, name, and every parameter, a value the
  # grammar must quote included. A parameter value is anything but the
  # controls (tab aside) and DQUOTE, which neither spelling can hold.
  def test_a_rendered_header_reads_back_as_the_property
    token = from_regex("[A-Za-z0-9-]{1,10}", fullmatch: true)
    parameter_value = from_regex('[^\x00-\x08\x0a-\x1f\x7f"]{0,12}', fullmatch: true)
    value = from_regex('[^\r\n]{0,40}', fullmatch: true)
    Hegel.test(test_cases: 1_000) do |tc|
      property = ProTacts::VCard::Parser::Property.new(
        group: tc.draw(optional(token)),
        name: tc.draw(token),
        parameters: tc.draw(arrays(tuples(token, parameter_value), max_size: 4)),
        value: tc.draw(value),
      )
      line = "#{ProTacts::VCard.header_of(property)}#{property.value}\r\n"

      assert_equal [property], ProTacts::VCard::Parser.lines(line).map(&:property)
    end
  end

  ## The card's bytes

  # Relabelling bytes is not converting them, so bytes that are not
  # UTF-8 at all never become a card: better than a store serving them
  # back as `text/vcard; charset=utf-8` while they are no such thing.
  # Relabelled first, as the route would (Web#write_card), and this
  # pins the line that catches it: the card, before any walk, bind, or
  # store could meet the bytes.
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
