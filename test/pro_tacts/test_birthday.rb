require_relative "../test_helper"

require "hegel"

require "pro_tacts/birthday"
require "pro_tacts/vcard"

class BirthdayTest < Minitest::Test
  include Hegel::Syntax::Methods

  # The six shapes RFC 6350 section 4.3.1 admits, one assertion per
  # shape so a failure names the one that broke.
  def test_every_admitted_shape_constructs
    ProTacts::Birthday.new(year: 1985, month: 4, day: 12)
    ProTacts::Birthday.new(year: 1985, month: 4)
    ProTacts::Birthday.new(year: 1985)
    ProTacts::Birthday.new(month: 4, day: 12)
    ProTacts::Birthday.new(month: 4)
    ProTacts::Birthday.new(day: 12)
  end

  # The two the grammar refuses: year with day but no month has no form
  # a date can take, and a birthday that is nothing at all is not one.
  def test_the_shapes_the_grammar_refuses
    error = assert_raises(ArgumentError) { ProTacts::Birthday.new(year: 1985, day: 12) }
    assert_match "not a shape", error.message

    assert_raises(ArgumentError) { ProTacts::Birthday.new }
  end

  def test_components_out_of_range_are_refused
    assert_raises(ArgumentError) { ProTacts::Birthday.new(month: 13, day: 12) }
    assert_raises(ArgumentError) { ProTacts::Birthday.new(month: 4, day: 32) }
    assert_raises(ArgumentError) { ProTacts::Birthday.new(year: 10_000, month: 4, day: 12) }
  end

  # A String misses the range patterns and is refused; a non-Integer
  # numeric would pass, a boundary Birthday.new's comment explains.
  def test_components_that_are_not_integers_are_refused
    assert_raises(ArgumentError) { ProTacts::Birthday.new(year: "1985", month: 4, day: 12) }
    assert_raises(ArgumentError) { ProTacts::Birthday.new(year: 1985, month: "4", day: 12) }
  end

  def test_the_wire_forms
    assert_equal "BDAY:1985-04-12", ProTacts::Birthday.new(year: 1985, month: 4, day: 12).to_line
    assert_equal "BDAY;X-APPLE-OMIT-YEAR=1604:1604-04-12", ProTacts::Birthday.new(month: 4, day: 12).to_line
  end

  def test_the_shapes_no_client_displays_serve_nothing
    [ProTacts::Birthday.new(year: 1985, month: 4), ProTacts::Birthday.new(year: 1985),
      ProTacts::Birthday.new(month: 4), ProTacts::Birthday.new(day: 12)].each do |birthday|
      assert_nil birthday.to_line
      refute birthday.served?
    end
  end

  def test_the_served_shapes
    [ProTacts::Birthday.new(year: 1985, month: 4, day: 12), ProTacts::Birthday.new(month: 4, day: 12)].each do |birthday|
      assert birthday.served?
    end
  end

  ## to_s

  # One rendering per admitted shape, the same six the constructor
  # accepts, so every display of a birthday agrees.
  def test_to_s_renders_every_admitted_shape
    assert_equal "April 12, 1985", ProTacts::Birthday.new(year: 1985, month: 4, day: 12).to_s
    assert_equal "April 1985", ProTacts::Birthday.new(year: 1985, month: 4).to_s
    assert_equal "1985", ProTacts::Birthday.new(year: 1985).to_s
    assert_equal "April 12", ProTacts::Birthday.new(month: 4, day: 12).to_s
    assert_equal "April", ProTacts::Birthday.new(month: 4).to_s
    assert_equal "12", ProTacts::Birthday.new(day: 12).to_s
  end

  # Rendering carries no calendar: February 30 is impossible but
  # well-shaped, and the prose names the day it says rather than
  # refusing to render at all.
  def test_to_s_renders_calendar_nonsense_as_the_day_it_names
    assert_equal "February 30, 1985", ProTacts::Birthday.new(year: 1985, month: 2, day: 30).to_s
  end

  ## next_on

  # A birthday still ahead this year lands this year, and one already
  # here today lands today rather than a year out.
  def test_next_on_lands_this_year_from_today_on
    today = Date.new(2026, 9, 3)

    assert_equal Date.new(2026, 9, 4), ProTacts::Birthday.new(year: 1985, month: 9, day: 4).next_on(today)
    assert_equal Date.new(2026, 9, 3), ProTacts::Birthday.new(month: 9, day: 3).next_on(today)
  end

  def test_next_on_wraps_a_passed_birthday_onto_next_year
    assert_equal Date.new(2027, 3, 15), ProTacts::Birthday.new(year: 1990, month: 3, day: 15).next_on(Date.new(2026, 9, 3))
  end

  # Only a month and a day together name a calendar day.
  def test_next_on_is_nil_for_the_shapes_on_no_calendar_day
    today = Date.new(2026, 9, 3)

    [
      ProTacts::Birthday.new(year: 1985, month: 4),
      ProTacts::Birthday.new(year: 1985),
      ProTacts::Birthday.new(month: 4),
      ProTacts::Birthday.new(day: 12),
    ].each { |birthday| assert_nil birthday.next_on(today) }
  end

  # Well-shaped but calendar-nonsense lands on the month's last day,
  # the year's own February deciding which: 29 in a leap year.
  def test_next_on_puts_a_day_the_month_does_not_have_on_its_last_day
    nonsense = ProTacts::Birthday.new(year: 1980, month: 2, day: 30)

    assert_equal Date.new(2027, 2, 28), nonsense.next_on(Date.new(2026, 9, 3))
    assert_equal Date.new(2028, 2, 29), nonsense.next_on(Date.new(2027, 9, 3))
  end

  ## from_property

  # A parsed property, the shape a read out of a card takes.
  def property(value, parameters: [], group: nil)
    ProTacts::VCard::Parser::Property.new(group:, name: "BDAY", parameters:, value:)
  end

  def test_every_well_shaped_spelling_reads
    {
      "1985-04-12" => ProTacts::Birthday.new(year: 1985, month: 4, day: 12),
      "--0412" => ProTacts::Birthday.new(month: 4, day: 12),
      "--04-12" => ProTacts::Birthday.new(month: 4, day: 12),
      "1985-04" => ProTacts::Birthday.new(year: 1985, month: 4),
      "1985" => ProTacts::Birthday.new(year: 1985),
      "--04" => ProTacts::Birthday.new(month: 4),
      "---12" => ProTacts::Birthday.new(day: 12),
    }.each do |value, birthday|
      assert_equal birthday, ProTacts::Birthday.from_property(property(value)), value
    end
  end

  # docs/apple-contacts.md, "Birthdays without a year": the verified
  # Apple form, with 1604 standing in for the year in both halves.
  def test_the_apple_no_year_form_reads_into_the_model
    sentinel = property("1604-04-12", parameters: [["X-APPLE-OMIT-YEAR", "1604"]])

    assert_equal ProTacts::Birthday.new(month: 4, day: 12), ProTacts::Birthday.from_property(sentinel)
  end

  # iOS writes the sentinel back without its parameter, so 1604 means no
  # year on its own (docs/plans/2026-09-11-every-birthday-in-the-model.md).
  def test_a_1604_date_has_no_year
    [property("1604-03-08"), property("1604-03-08", parameters: [["value", "date"]])].each do |ios|
      assert_equal ProTacts::Birthday.new(month: 3, day: 8), ProTacts::Birthday.from_property(ios)
    end
  end

  # RFC 2426 section 3.1.5 lets BDAY carry a date and time; the time is
  # the one thing ingest deliberately loses, because a birthday is a
  # date — the design record's decision, not an oversight.
  def test_a_date_time_loses_its_time_on_the_way_in
    ["1985-04-12T23:10:00Z", "1985-04-12T08:30:00-06:00"].each do |value|
      assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12),
        ProTacts::Birthday.from_property(property(value)), value
    end
  end

  def test_names_and_parameters_match_without_case
    sentinel = property("1604-04-12", parameters: [["x-apple-omit-year", "1604"]])

    assert_equal ProTacts::Birthday.new(month: 4, day: 12), ProTacts::Birthday.from_property(sentinel)
  end

  # VALUE=date names BDAY's default type (RFC 2426 section 3.1.5), and
  # iOS spells it out on every birthday it writes.
  def test_value_date_reads_as_the_bare_line_would
    assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12),
      ProTacts::Birthday.from_property(property("1985-04-12", parameters: [["value", "date"]]))
    assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12),
      ProTacts::Birthday.from_property(property("1985-04-12", parameters: [["VALUE", "DATE"]]))

    sentinel = property("1604-04-12", parameters: [["VALUE", "date"], ["X-APPLE-OMIT-YEAR", "1604"]])
    assert_equal ProTacts::Birthday.new(month: 4, day: 12), ProTacts::Birthday.from_property(sentinel)
  end

  # Everything else reads as nil and stays in the card verbatim (RFC
  # 6352 section 6.3.2.2): a value out of range or in no spelling this
  # reads, a parameter that travels with its line, the sentinel's
  # parameter on a date it does not stand in for, and a grouped
  # property, whose label pairing belongs to the card.
  def test_what_the_model_does_not_take_reads_as_nil
    [property("1985-13-40"), property("--0432"), property("19850412"), property("banana"), property(""),
      property("1985-04-12", parameters: [["X-OTHER", "1"]]),
      property("1985-04-12", parameters: [["VALUE", "text"]]),
      property("1985-04-12", parameters: [["X-APPLE-OMIT-YEAR", "1604"]]),
      property("1604-04-12", parameters: [["X-APPLE-OMIT-YEAR", "1604"], ["X-OTHER", "1"]]),
      property("1985-04-12", group: "item1"), property("--0412", group: "item1")].each do |unmodeled|
      assert_nil ProTacts::Birthday.from_property(unmodeled), unmodeled.value
    end
  end

  ## Property tests

  # Any birthday the constructor admits, all six shapes.
  def any_birthday
    year = integers(min_value: 0, max_value: 9999)
    month = integers(min_value: 1, max_value: 12)
    day = integers(min_value: 1, max_value: 31)
    one_of(
      tuples(year, month, day), tuples(year, month, just(nil)), tuples(year, just(nil), just(nil)),
      tuples(just(nil), month, day), tuples(just(nil), month, just(nil)), tuples(just(nil), just(nil), day),
    ).map { |y, m, d| ProTacts::Birthday.new(year: y, month: m, day: d) }
  end

  # The spellings a shape is read in (the patterns on Birthday): a
  # full date bare or with any time RFC 2426 section 3.1.5 allows,
  # and a month-day in both its basic and extended form.
  def spelling(birthday)
    y = birthday.year&.then { format("%04d", it) }
    m, d = [birthday.month, birthday.day].map { it&.then { format("%02d", it) } }
    case [y, m, d]
    in [String, String, String]
      from_regex("(T[0-9]{2}:?[0-9]{2}(:?[0-9]{2}(\\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})?)?", fullmatch: true)
        .map { "#{y}-#{m}-#{d}#{it}" }
    in [nil, String, String] then sampled_from(["--#{m}#{d}", "--#{m}-#{d}"])
    in [String, String, nil] then just("#{y}-#{m}")
    in [String, nil, nil] then just(y)
    in [nil, String, nil] then just("--#{m}")
    in [nil, nil, String] then just("---#{d}")
    end
  end

  # Every admitted birthday, in every spelling its shape has, reads
  # back as itself — VALUE=date or not, which names the default and
  # so says nothing. A full date in 1604 is the one that reads as
  # something else, a month and day (Birthday::NO_YEAR, and
  # docs/plans/2026-09-11-every-birthday-in-the-model.md, "1604 means
  # no year"); a partial date in 1604 keeps its year.
  def test_every_spelling_of_every_shape_reads_back
    Hegel.test(test_cases: 1_000) do |tc|
      birthday = tc.draw(any_birthday)
      value = tc.draw(spelling(birthday))
      parameters = tc.draw(sampled_from([[], [["VALUE", "date"]], [["value", "DATE"]]]))

      expected = birthday.year == 1604 && birthday.day ? birthday.with(year: nil) : birthday
      assert_equal expected, ProTacts::Birthday.from_property(property(value, parameters:))
    end
  end

  # A spelling with one component out of its range is in no spelling
  # this reads, so it stays in the card as it came rather than reaching
  # a constructor that would refuse it.
  def test_a_component_out_of_range_reads_as_nothing
    Hegel.test(test_cases: 1_000) do |tc|
      month = tc.draw(one_of(just(0), integers(min_value: 13, max_value: 99)).map { it.to_s.rjust(2, "0") })
      day = tc.draw(one_of(just(0), integers(min_value: 32, max_value: 99)).map { it.to_s.rjust(2, "0") })
      value = tc.draw(sampled_from(["1985-#{month}-12", "1985-04-#{day}", "--#{month}12", "--04#{day}",
                                    "1985-#{month}", "--#{month}", "---#{day}"]))

      assert_nil ProTacts::Birthday.from_property(property(value))
    end
  end

  # What a served birthday sends, read back the way a client's PUT of
  # it is read, is the birthday it was — the round trip that serving
  # only the two shapes Apple keeps exists for, a 1604 full date
  # aside as above.
  def test_a_served_birthday_reads_back_from_its_line
    Hegel.test(test_cases: 1_000) do |tc|
      birthday = tc.draw(any_birthday)
      tc.assume(birthday.served?)

      read = ProTacts::VCard::Parser.lines("#{birthday.to_line}\r\n").fetch(0).property
      expected = birthday.year == 1604 ? birthday.with(year: nil) : birthday
      assert_equal expected, ProTacts::Birthday.from_property(read)
    end
  end

  # The day a birthday next lands on is the first day from today on
  # that is its day — the month's last when the month has no such day
  # — so none is skipped and none comes early.
  def test_next_on_is_the_first_day_from_today_that_is_the_birthday
    Hegel.test(test_cases: 1_000) do |tc|
      birthday = tc.draw(any_birthday)
      tc.assume(birthday.month && birthday.day)
      today = tc.draw(dates(min_value: Date.new(1900, 1, 1), max_value: Date.new(2200, 12, 31)))

      lands = ->(date) { date.month == birthday.month && date.day == [birthday.day, Date.new(date.year, date.month, -1).day].min }
      assert_equal (today..).find(&lands), birthday.next_on(today)
    end
  end
end
