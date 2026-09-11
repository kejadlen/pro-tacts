require_relative "../test_helper"

require "pro_tacts/birthday"
require "pro_tacts/vcard"

class BirthdayTest < Minitest::Test
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

  # The shape pattern matches by range, and a range admits any
  # Comparable within its bounds — so a String component is refused as a
  # shape problem. A non-Integer numeric would pass; no producer can
  # make one (SQLite integer columns and #to_i are Integers), which the
  # constructor's comment records as the boundary of the check.
  def test_components_that_are_not_integers_are_refused
    assert_raises(ArgumentError) { ProTacts::Birthday.new(year: "1985", month: 4, day: 12) }
    assert_raises(ArgumentError) { ProTacts::Birthday.new(year: 1985, month: "4", day: 12) }
  end

  def test_the_wire_forms
    assert_equal "BDAY:1985-04-12", ProTacts::Birthday.new(year: 1985, month: 4, day: 12).to_line
    assert_equal "BDAY;X-APPLE-OMIT-YEAR=1604:1604-04-12", ProTacts::Birthday.new(month: 4, day: 12).to_line
  end

  # The four shapes no client displays are never sent.
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
end
