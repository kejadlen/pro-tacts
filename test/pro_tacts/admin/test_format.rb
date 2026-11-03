require_relative "../../test_helper"

require "hegel"

require "pro_tacts/admin/format"
require "pro_tacts/vcard"

class FormatTest < Minitest::Test
  include Hegel::Syntax::Methods

  # Search compares on the fold, not the spelling: an accent never
  # hides the letter it sits on, and a letter another script spells
  # stays — ASCII-only matching would make that name unfindable.
  def test_search_key_folds_accents_and_keeps_whole_letters
    assert_equal "emile munoz", ProTacts::Admin::Format.search_key("Émile Muñoz")
    assert_equal "νικος", ProTacts::Admin::Format.search_key("Νίκος")
    assert_equal "straße", ProTacts::Admin::Format.search_key("Straße")
  end

  def test_an_etag_shows_as_a_short_bare_hash
    etag = %("#{"ab12cd34ef56" * 5}")

    assert_equal "ab12cd34ef56…", ProTacts::Admin::Format.short_etag(etag)
  end

  def test_a_hash_no_longer_than_the_cut_keeps_every_digit
    assert_equal "ab12cd34", ProTacts::Admin::Format.short_etag(%("ab12cd34"))
  end

  def test_a_stamp_drops_the_milliseconds_and_nothing_else
    assert_equal "2026-09-04T20:35:22Z",
                 ProTacts::Admin::Format.stamp("2026-09-04T20:35:22.481Z")
  end

  def test_a_stamp_without_milliseconds_is_left_alone
    assert_equal "2026-09-04T20:35:22Z",
                 ProTacts::Admin::Format.stamp("2026-09-04T20:35:22Z")
  end

  def test_time_ago_buckets_by_how_long_ago
    now = Time.now.utc

    assert_equal "just now", ProTacts::Admin::Format.time_ago(now.iso8601(3))
    assert_equal "5m ago", ProTacts::Admin::Format.time_ago((now - 5 * 60).iso8601(3))
    assert_equal "2h ago", ProTacts::Admin::Format.time_ago((now - 2 * 3600).iso8601(3))
    assert_equal "3d ago", ProTacts::Admin::Format.time_ago((now - 3 * 86_400).iso8601(3))
    assert_equal "2mo ago", ProTacts::Admin::Format.time_ago((now - 60 * 86_400).iso8601(3))
  end

  ## Property tests

  # A search key is already folded, so folding it again changes
  # nothing: a query and a value both reach the comparison as keys,
  # however many times either was folded on the way.
  def test_a_search_key_is_its_own_key
    Hegel.test(test_cases: 1_000) do |tc|
      key = ProTacts::Admin::Format.search_key(tc.draw(text(max_size: 20)))

      assert_equal key, ProTacts::Admin::Format.search_key(key)
    end
  end

  ## Eliding a line

  # An elided line still reads as the line it stands for: its group,
  # its name, and each parameter, a long value as its count and every
  # other as it was — quoted where the grammar must quote it, so a
  # parameter holding `:` or `,` is not cut apart on the way to the
  # screen.
  def test_an_elided_line_reads_as_its_line_with_long_values_counted
    token = from_regex("[A-Za-z0-9-]{1,8}", fullmatch: true)
    short = from_regex('[^\x00-\x08\x0a-\x1f\x7f"]{0,12}', fullmatch: true)
    long = from_regex("[a-z:,;]{121,140}", fullmatch: true)
    Hegel.test(test_cases: 1_000) do |tc|
      property = ProTacts::VCard::Parser::Property.new(
        group: tc.draw(optional(token)),
        name: tc.draw(token),
        parameters: tc.draw(arrays(tuples(token, one_of(short, long)), max_size: 3)),
        value: tc.draw(one_of(short.map { it.delete(":;,\\") }, long)),
      )
      line = ProTacts::VCard.new("#{ProTacts::VCard.header_of(property)}#{property.value}\r\n").lines.fetch(0)
      count = ->(value) { value.bytesize > ProTacts::Admin::Format::ELIDE_ABOVE ? "[#{value.bytesize} octets elided]" : value }

      elided = ProTacts::VCard.new(ProTacts::Admin::Format.elide_line(line)).lines.fetch(0).property

      assert_equal property.with(parameters: property.parameters.map { [it[0], count.(it[1])] }, value: count.(property.value)),
                   elided
    end
  end
end
