require_relative "../../test_helper"

require "pro_tacts/admin/format"
require "pro_tacts/contact"
require "pro_tacts/vcard"

class FormatTest < Minitest::Test
  CARD = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Ada Lovelace\r\nN:Lovelace;Ada;;;\r\n" \
    "UID:ada\r\nEND:VCARD\r\n"

  # The production shapes: a modeled birthday passes a BDAY-free card
  # beside a Birthday, a fallback case passes a card carrying an
  # unmodeled BDAY beside nil, and inheritance defaults to none (see
  # Contact).
  def contact(vcard = CARD, id: "aiden", birthday: nil, inherited: [])
    ProTacts::Contact.for(id:, stored: ProTacts::VCard.new(vcard), birthday:, inherited:)
  end

  # Initials come from the structured N property (given + family),
  # not a guess at word boundaries in the free-text FN.
  def test_initials_come_from_the_structured_name
    assert_equal "AL", ProTacts::Admin::Format.initials(contact)
  end

  # A card with no N at all — an organization's own entry, say — falls
  # back to one first letter of FN.
  def test_initials_fall_back_to_the_display_name_with_no_n_property
    no_n = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Riverside Elementary\r\nUID:office\r\nEND:VCARD\r\n"

    assert_equal "R", ProTacts::Admin::Format.initials(contact(no_n))
  end

  def test_initials_fall_back_to_the_id_when_there_is_no_name_at_all
    bare = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:zz9\r\nEND:VCARD\r\n"

    assert_equal "Z", ProTacts::Admin::Format.initials(contact(bare, id: "znorth"))
  end

  # A blank FN is no name — empty values read as absent (see
  # Contact) — so initials fall back to the id like any nameless card.
  def test_initials_of_a_blank_name_fall_back_to_the_id
    blank = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:\r\nUID:b\r\nEND:VCARD\r\n"

    assert_equal "A", ProTacts::Admin::Format.initials(contact(blank))
  end

  # N with only one of given/family present (a mononym, or a card that
  # only bothered with a family name) still gives one initial rather
  # than raising on the missing half.
  def test_initials_from_a_partial_n_property
    family_only = CARD.sub("N:Lovelace;Ada;;;", "N:Lovelace;;;;")

    assert_equal "L", ProTacts::Admin::Format.initials(contact(family_only))
  end

  def test_formats_the_birthday
    birthday = ProTacts::Birthday.new(year: 1985, month: 12, day: 10)

    assert_equal "December 10, 1985", ProTacts::Admin::Format.birthday(contact(CARD, birthday:))
  end

  # RFC 2426 section 3.1.5 lets BDAY carry a date-time, and a client is
  # free to send one; the display reads only the date part of a bare
  # value it meets — the same drop the write path makes on the way in
  # (Birthday.from_property).
  def test_a_birthday_with_a_time_component_still_formats
    with_time = CARD.sub("END:VCARD\r\n", "BDAY:1985-12-10T00:00:00Z\r\nEND:VCARD\r\n")

    assert_equal "December 10, 1985", ProTacts::Admin::Format.birthday(contact(with_time))
  end

  # Apple's 1604-sentinel spelling for "no year on file" (see
  # ProTacts::Birthday), the model shape the served card carries.
  def test_a_birthday_with_no_year_omits_one
    birthday = ProTacts::Birthday.new(month: 12, day: 10)

    assert_equal "December 10", ProTacts::Admin::Format.birthday(contact(CARD, birthday:))
  end

  # The reduced no-year spelling (Birthday::REDUCED_DATE), which macOS
  # reads on a card it did not write: the model does not recompose it,
  # so the line stays in the card verbatim — display renders it as a
  # day all the same, not as the stored string.
  def test_a_reduced_no_year_birthday_displays_its_day
    reduced = CARD.sub("END:VCARD\r\n", "BDAY:--12-10\r\nEND:VCARD\r\n")

    assert_equal "December 10", ProTacts::Admin::Format.birthday(contact(reduced))
  end

  # The undashed variant of the reduced spelling.
  def test_an_undashed_reduced_no_year_birthday_displays_its_day
    basic = CARD.sub("END:VCARD\r\n", "BDAY:--1210\r\nEND:VCARD\r\n")

    assert_equal "December 10", ProTacts::Admin::Format.birthday(contact(basic))
  end

  # Calendar-nonsense in the reduced spelling, rendered as the day it
  # names like the modeled one below.
  def test_a_calendar_nonsense_reduced_no_year_birthday_renders_its_components
    nonsense = CARD.sub("END:VCARD\r\n", "BDAY:--02-30\r\nEND:VCARD\r\n")

    assert_equal "February 30", ProTacts::Admin::Format.birthday(contact(nonsense))
  end

  def test_a_birthday_that_will_not_parse_is_shown_as_stored
    unparseable = CARD.sub("END:VCARD\r\n", "BDAY:not-a-date\r\nEND:VCARD\r\n")

    assert_equal "not-a-date", ProTacts::Admin::Format.birthday(contact(unparseable))
  end

  # Well-shaped but calendar-nonsense: the model checks component
  # ranges, not the calendar, and rendering is calendar-free — the
  # prose names the day it says rather than refusing to display.
  def test_a_calendar_nonsense_birthday_renders_its_components
    nonsense = ProTacts::Birthday.new(year: 1985, month: 2, day: 30)

    assert_equal "February 30, 1985", ProTacts::Admin::Format.birthday(contact(CARD, birthday: nonsense))
  end

  # The partial shapes no client renders still display: every form
  # the grammar admits has Birthday#to_s's one prose.
  def test_the_partial_shapes_display_their_components
    year_month = CARD.sub("END:VCARD\r\n", "BDAY:1985-10\r\nEND:VCARD\r\n")
    year = CARD.sub("END:VCARD\r\n", "BDAY:1985\r\nEND:VCARD\r\n")
    month = CARD.sub("END:VCARD\r\n", "BDAY:--07\r\nEND:VCARD\r\n")
    day = CARD.sub("END:VCARD\r\n", "BDAY:---04\r\nEND:VCARD\r\n")

    assert_equal "October 1985", ProTacts::Admin::Format.birthday(contact(year_month))
    assert_equal "1985", ProTacts::Admin::Format.birthday(contact(year))
    assert_equal "July", ProTacts::Admin::Format.birthday(contact(month))
    assert_equal "4", ProTacts::Admin::Format.birthday(contact(day))
  end

  def test_a_card_with_no_birthday_formats_none
    bare = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:bare\r\nEND:VCARD\r\n"

    assert_nil ProTacts::Admin::Format.birthday(contact(bare))
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
