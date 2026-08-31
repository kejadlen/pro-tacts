require_relative "../../test_helper"

require "pro_tacts/admin/format"

class FormatTest < Minitest::Test
  def test_initials_takes_the_first_letter_of_up_to_two_words
    assert_equal "AL", ProTacts::Admin::Format.initials("Ada Lovelace")
    assert_equal "A", ProTacts::Admin::Format.initials("Ada")
    assert_equal "RE", ProTacts::Admin::Format.initials("Riverside Elementary Front Office")
  end

  def test_initials_of_a_blank_name_is_blank
    assert_equal "", ProTacts::Admin::Format.initials("")
  end

  def test_time_ago_buckets_by_how_long_ago
    now = Time.now.utc

    assert_equal "just now", ProTacts::Admin::Format.time_ago(now.iso8601(3))
    assert_equal "5m ago", ProTacts::Admin::Format.time_ago((now - 5 * 60).iso8601(3))
    assert_equal "2h ago", ProTacts::Admin::Format.time_ago((now - 2 * 3600).iso8601(3))
    assert_equal "3d ago", ProTacts::Admin::Format.time_ago((now - 3 * 86_400).iso8601(3))
    assert_equal "2mo ago", ProTacts::Admin::Format.time_ago((now - 60 * 86_400).iso8601(3))
  end
end
