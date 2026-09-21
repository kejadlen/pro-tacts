require_relative "../../test_helper"

require "pro_tacts/import/vcf"

# Reading an uploaded .vcf: the split into cards, and the survey of
# what this address book does not show
# (docs/plans/2026-09-21-import-a-vcf.md).
class ImportVcfTest < Minitest::Test
  Vcf = ProTacts::Import::Vcf

  JANE = <<~CARD.gsub("\n", "\r\n")
    BEGIN:VCARD
    VERSION:3.0
    N:Booles;Jane;;;
    FN:Jane Booles
    TEL;type=CELL;type=VOICE;type=pref:+1 555 0100
    item1.ADR;type=HOME:;;1 Main St;Springfield;;;
    item1.X-ABLabel:_$!<Home>!$_
    item2.X-ABRELATEDNAMES:Sam Booles
    item2.X-ABLabel:_$!<Spouse>!$_
    X-SOCIALPROFILE;type=twitter:https://twitter.com/jb
    UID:ABC-123
    END:VCARD
  CARD

  SAM = <<~CARD.gsub("\n", "\r\n")
    BEGIN:VCARD
    VERSION:3.0
    N:Booles;Sam;;;
    FN:Sam Booles
    X-SOCIALPROFILE;type=facebook:https://facebook.com/sb
    PRODID:-//Apple Inc.//macOS 15.0//EN
    UID:DEF-456
    END:VCARD
  CARD

  def test_a_file_reads_as_the_cards_it_holds_byte_for_byte
    cards = Vcf.cards(JANE + SAM)

    assert_equal [JANE, SAM], cards.map(&:to_s)
  end

  # Contacts writes one card after another with nothing between them,
  # but an export edited by hand or joined with `cat` has blank lines,
  # and they are not a card's business.
  def test_blank_lines_between_cards_are_not_cards
    cards = Vcf.cards("#{JANE}\r\n\r\n#{SAM}")

    assert_equal [JANE, SAM], cards.map(&:to_s)
  end

  def test_a_line_outside_a_card_refuses_the_whole_file
    error = assert_raises(Vcf::Invalid) { Vcf.cards("FN:Stray\r\n#{JANE}") }

    assert_includes error.message, "FN:Stray"
  end

  def test_a_card_with_no_end_refuses_the_whole_file
    error = assert_raises(Vcf::Invalid) { Vcf.cards(JANE.sub("END:VCARD\r\n", "")) }

    assert_includes error.message, "no END:VCARD"
  end

  def test_a_file_with_no_cards_in_it_refuses
    error = assert_raises(Vcf::Invalid) { Vcf.cards("\r\n") }

    assert_includes error.message, "holds no vCards"
  end

  # BEGIN, VERSION and END are what makes a vCard (RFC 2426 section 4),
  # and VCard#card? is what says so — the same judgment a PUT makes.
  def test_something_shaped_like_a_card_without_a_version_refuses
    error = assert_raises(Vcf::Invalid) { Vcf.cards(JANE.sub("VERSION:3.0\r\n", "")) }

    assert_includes error.message, "are not vCards"
  end

  def test_the_survey_names_what_no_screen_here_shows
    unknown = Vcf.unknown(Vcf.cards(JANE + SAM))

    assert_equal %w[PRODID X-ABRELATEDNAMES X-SOCIALPROFILE], unknown.map(&:name)
  end

  # The envelope, the fields a screen shows, and the label that names a
  # row are all read here, so none of them is a decision.
  def test_the_survey_asks_nothing_about_a_property_this_book_reads
    names = Vcf.unknown(Vcf.cards(JANE + SAM)).map(&:name)

    refute_includes names, "TEL"
    refute_includes names, "X-ABLABEL"
    refute_includes names, "UID"
  end

  # The three choices read the same whatever parameters a line wears,
  # so a property is one decision however many spellings it arrives in.
  def test_parameters_do_not_make_a_second_decision
    social = Vcf.unknown(Vcf.cards(JANE + SAM)).find { it.name == "X-SOCIALPROFILE" }

    assert_equal 2, social.count
    assert_equal ["X-SOCIALPROFILE;type=twitter:https://twitter.com/jb",
                  "X-SOCIALPROFILE;type=facebook:https://facebook.com/sb"],
                 social.examples
  end

  # A choice is made looking at the book's own data, so the examples
  # are real lines — but no more of them than a list can be read at,
  # and never a picture's payload.
  def test_the_examples_are_a_few_real_lines_and_stop_short_of_a_payload
    cards = Vcf.cards((1..5).map { |n| JANE.sub("jb", "jb#{n}") }.join)

    examples = Vcf.unknown(cards).find { it.name == "X-SOCIALPROFILE" }.examples

    assert_equal Vcf::EXAMPLES, examples.length

    long = JANE.sub("https://twitter.com/jb", "x" * 400)

    example = Vcf.unknown(Vcf.cards(long)).find { it.name == "X-SOCIALPROFILE" }.examples.fetch(0)

    assert_includes example, "characters)"
    assert_operator example.length, :<, 200
  end

  # A line's value arrives folded across physical lines (RFC 2426
  # section 2.6); what it says is one line, and that is what the
  # screen shows.
  def test_an_example_is_unfolded
    folded = JANE.sub("X-SOCIALPROFILE;type=twitter:https://twitter.com/jb\r\n",
                      "X-SOCIALPROFILE;type=twitter:https://twitter.com\r\n /jb\r\n")

    example = Vcf.unknown(Vcf.cards(folded)).find { it.name == "X-SOCIALPROFILE" }.examples.fetch(0)

    assert_equal "X-SOCIALPROFILE;type=twitter:https://twitter.com/jb", example
  end
  # One card as this book will hold it: the lines it reads, in the
  # bytes and the order they arrived.
  def test_reading_a_card_keeps_what_a_screen_here_shows
    landing = Vcf.read(Vcf.cards(JANE).fetch(0)).card.to_s

    assert_includes landing, "N:Booles;Jane;;;\r\n"
    assert_includes landing, "TEL;type=CELL;type=VOICE;type=pref:+1 555 0100\r\n"
    assert_includes landing, "item1.ADR;type=HOME:;;1 Main St;Springfield;;;\r\n"
    assert_includes landing, "UID:ABC-123\r\n"
    # Still a card: the envelope is read like anything else.
    assert Vcf.cards(landing).fetch(0).card?
  end

  def test_reading_a_card_leaves_behind_what_no_screen_shows
    reading = Vcf.read(Vcf.cards(JANE).fetch(0))

    refute_includes reading.card.to_s, "X-SOCIALPROFILE"
    refute_includes reading.card.to_s, "X-ABRELATEDNAMES"
    assert_includes reading.dropped.map { Vcf.summary(it) },
                    "X-SOCIALPROFILE;type=twitter:https://twitter.com/jb"
  end

  # Apple hangs a row's label off the line it names rather than
  # inside it, so a label whose line is leaving has nothing left to
  # name — while the label on a line that is coming in comes with it.
  def test_a_label_goes_wherever_the_line_it_names_goes
    reading = Vcf.read(Vcf.cards(JANE).fetch(0))

    assert_includes reading.card.to_s, "item1.X-ABLabel:_$!<Home>!$_\r\n"
    refute_includes reading.card.to_s, "_$!<Spouse>!$_"
    assert_includes reading.dropped.map { Vcf.summary(it) }, "item2.X-ABLabel:_$!<Spouse>!$_"
  end

  # There is no property name to have shown on a screen and nothing
  # anyone could have decided about it, so it rides along rather than
  # being thrown away unnamed.
  def test_a_line_that_will_not_read_is_kept
    broken = JANE.sub("FN:Jane Booles\r\n", "FN:Jane Booles\r\nnot a content line\r\n")

    reading = Vcf.read(Vcf.cards(broken).fetch(0))

    assert_includes reading.card.to_s, "not a content line\r\n"
    assert_empty reading.dropped.select { it.property.nil? }
  end
end
