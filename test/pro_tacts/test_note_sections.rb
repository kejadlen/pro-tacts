require_relative "../test_helper"

require "pro_tacts/note_sections"

# The text algebra of the one NOTE a served card carries, on its own
# with no contact and no group: what composition writes and what a PUT
# reads, per docs/plans/2026-09-25-one-note-per-contact.md. The join
# and the split it reads with are tested together where they agree, and
# each alone where they do not — the split tolerating the whitespace a
# person's editing moves, the join writing one shape only.
class NoteSectionsTest < Minitest::Test
  NEIGHBOURS = ProTacts::NoteSections.header("Neighbours") #: String

  def section(label, text) = ProTacts::NoteSections::Section.new(label:, text:)

  def split(value, labels) = ProTacts::NoteSections.split(value, labels)

  ## The join

  def test_member_text_and_one_section
    sections = [section("Neighbours", "bins go out on Tuesday")]

    assert_equal "gate code 1854\n\n#{NEIGHBOURS}\nbins go out on Tuesday",
      ProTacts::NoteSections.join("gate code 1854", sections)
  end

  def test_a_section_alone_loses_no_blank_it_never_had
    assert_equal "#{NEIGHBOURS}\nbins go out on Tuesday",
      ProTacts::NoteSections.join("", [section("Neighbours", "bins go out on Tuesday")])
  end

  def test_sections_come_in_the_order_given
    value = ProTacts::NoteSections.join(
      "",
      [section("Neighbours", "bins"), section("Dog walkers", "Sunday")],
    )

    assert_equal "#{NEIGHBOURS}\nbins\n\n#{ProTacts::NoteSections.header('Dog walkers')}\nSunday", value
  end

  def test_a_multiline_body_keeps_its_paragraphs
    value = ProTacts::NoteSections.join("own", [section("Neighbours", "first line\n\nsecond line")])

    assert_equal "own\n\n#{NEIGHBOURS}\nfirst line\n\nsecond line", value
  end

  def test_a_bodyless_section_is_its_header
    assert_equal "#{NEIGHBOURS}", ProTacts::NoteSections.join("", [section("Neighbours", "")])
  end

  ## The split

  def test_the_joined_shape_reads_back
    value = ProTacts::NoteSections.join(
      "gate code 1854\ncall before visiting",
      [section("Neighbours", "bins go out on Tuesday\ngreen bin alternates")],
    )

    read = split(value, ["Neighbours"])

    assert_equal "gate code 1854\ncall before visiting", read.member
    assert_equal [section("Neighbours", "bins go out on Tuesday\ngreen bin alternates")], read.sections
  end

  def test_a_label_nothing_lends_is_member_text
    read = split("pastedin\n#{NEIGHBOURS}\nnot lent", [])

    assert_equal "pastedin\n#{NEIGHBOURS}\nnot lent", read.member
    assert_empty read.sections
  end

  def test_whitespace_between_sections_is_not_structure
    read = split("own\n#{NEIGHBOURS}\nlent\n\n\n", ["Neighbours"])

    assert_equal "own", read.member
    assert_equal [section("Neighbours", "lent")], read.sections
  end

  def test_a_header_tolerates_trailing_whitespace
    read = split("own\n#{NEIGHBOURS}  \nlent", ["Neighbours"])

    assert_equal [section("Neighbours", "lent")], read.sections
  end

  def test_an_indented_header_is_member_text
    read = split("own\n #{NEIGHBOURS}\nlent", ["Neighbours"])

    assert_equal "own\n #{NEIGHBOURS}\nlent", read.member
    assert_empty read.sections
  end

  def test_blank_lines_around_the_member_are_the_separator
    read = split("\n\nown\n\n#{NEIGHBOURS}\nlent", ["Neighbours"])

    assert_equal "own", read.member
    assert_equal [section("Neighbours", "lent")], read.sections
  end

  def test_a_member_of_all_blanks_is_no_member
    read = split("\n\n#{NEIGHBOURS}\nlent", ["Neighbours"])

    assert_equal "", read.member
  end

  def test_two_sections_of_one_label_stay_two
    read = split("#{NEIGHBOURS}\nfirst\n\n#{NEIGHBOURS}\nsecond", ["Neighbours"])

    assert_equal [section("Neighbours", "first"), section("Neighbours", "second")], read.sections
  end

  def test_sections_read_in_the_order_they_stand
    read = split(
      "#{ProTacts::NoteSections.header('Dog walkers')}\nSunday\n\n#{NEIGHBOURS}\nbins",
      ["Neighbours", "Dog walkers"],
    )

    assert_equal [section("Dog walkers", "Sunday"), section("Neighbours", "bins")], read.sections
  end
end
