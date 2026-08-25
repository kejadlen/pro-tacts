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
end
