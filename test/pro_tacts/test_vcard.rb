require_relative "../test_helper"

require "hegel"

require "pro_tacts/vcard"

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

  ## Property tests

  def test_unfolding_reverses_folding
    Hegel.test do |tc|
      value = tc.draw(text(max_size: 300))
      line = "NOTE:#{ProTacts::VCard.escape(value)}"

      raise "unfold did not reverse fold" unless ProTacts::VCard.unfold(ProTacts::VCard.fold(line)) == line
    end
  end

  ## The envelope

  # What a PUT checks before storing: RFC 2426 section 4 has a card
  # begin and end itself and declare a version, and lines that parse
  # into properties are not yet a card.
  CARD = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"

  def test_properties_with_the_envelope_are_a_card
    assert ProTacts::VCard.card?(ProTacts::VCard::Parser.parse(CARD))
  end

  def test_no_properties_are_not_a_card
    refute ProTacts::VCard.card?([])
  end

  def test_each_piece_of_the_envelope_is_required
    no_begin = "VERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"
    no_end = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\n"
    no_version = "BEGIN:VCARD\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"

    [no_begin, no_end, no_version].each do |card|
      refute ProTacts::VCard.card?(ProTacts::VCard::Parser.parse(card)), card
    end
  end

  def test_envelope_names_compare_without_case
    lowercase = "begin:vcard\r\nversion:3.0\r\nfn:Aiden\r\nuid:aiden\r\nend:vcard\r\n"
    properties = ProTacts::VCard::Parser.parse(lowercase)

    assert ProTacts::VCard.card?(properties)
    assert_equal "aiden", ProTacts::VCard.uid(properties)
  end

  def test_a_card_without_a_uid_has_none
    card = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nEND:VCARD\r\n"

    assert_nil ProTacts::VCard.uid(ProTacts::VCard::Parser.parse(card))
  end
end
