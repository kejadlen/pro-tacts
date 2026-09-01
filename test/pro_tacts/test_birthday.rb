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

  # The four shapes no client has been verified to accept reach no wire;
  # this is the set the deletion rule treats as invisible.
  def test_the_shapes_without_a_verified_spelling_serve_nothing
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

  ## from_property

  # A parsed property, the shape a read out of a card takes.
  def property(value, parameters: [], group: nil)
    ProTacts::VCard::Property.new(group:, name: "BDAY", parameters:, value:)
  end

  def test_a_full_date_reads_into_the_model
    assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12),
      ProTacts::Birthday.from_property(property("1985-04-12"))
  end

  # docs/macos-contacts.md, "Birthdays without a year": the verified
  # Apple form, with 1604 standing in for the year in both halves.
  def test_the_apple_no_year_form_reads_into_the_model
    sentinel = property("1604-04-12", parameters: [["X-APPLE-OMIT-YEAR", "1604"]])

    assert_equal ProTacts::Birthday.new(month: 4, day: 12), ProTacts::Birthday.from_property(sentinel)
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

  # A component out of range is unmodeled, not exceptional: from_property
  # reads nil and the line stays wherever it was. Store reports the value
  # as unrecognized, so the swallow is not silent.
  def test_an_out_of_range_date_reads_as_nil
    assert_nil ProTacts::Birthday.from_property(property("1985-13-40"))
  end

  # Everything the model cannot recompose reads as nil, keeping it in
  # the card verbatim (RFC 6352 section 6.3.2.2): extra parameters
  # travel with their line, and a grouped property's label pairing
  # belongs to the card.
  def test_what_the_model_cannot_recompose_reads_as_nil
    [property("--0412"), property("1985-04"), property("19850412"),
      property("1985-04-12", parameters: [["X-OTHER", "1"]]),
      property("1604-04-12", parameters: [["X-APPLE-OMIT-YEAR", "1604"], ["X-OTHER", "1"]]),
      property("1985-04-12", group: "item1")].each do |unmodeled|
      assert_nil ProTacts::Birthday.from_property(unmodeled), unmodeled.value
    end
  end

  ## the values no client renders

  def test_unrendered_value_accepts_the_four_shapes_spellings
    ["1985-04", "1985", "--04", "---12"].each do |value|
      assert ProTacts::Birthday.unrendered_value?(value), value
    end
  end

  # The rendered set matches none of the four, and a value the grammar
  # will not read matches nothing. The padded pair pins the anchors —
  # each pattern is anchored alone, so no spelling matches inside a
  # longer or padded value.
  def test_unrendered_value_refuses_everything_else
    ["1985-04-12", "--0412", "--04-12", "19850412", "1985-4", "1985-13", "--00", "", "x1985", "1985-04\n"].each do |value|
      refute ProTacts::Birthday.unrendered_value?(value), value
    end
  end

  ## the values a client renders

  # from_property's two spellings, the reduced no-year values macOS
  # additionally reads, and their case: a client that renders a BDAY
  # can have deleted it, so its absence from a rewrite is a removal.
  def test_rendered_reads_the_spellings_clients_show
    [property("1985-04-12"), property("1985-04-12T23:10:00Z"),
      property("1604-04-12", parameters: [["X-APPLE-OMIT-YEAR", "1604"]]),
      property("--0412"), property("--04-12")].each do |rendered|
      assert ProTacts::Birthday.rendered?(rendered), rendered.value
    end
  end

  # What no client renders — the carried shapes, the out-of-range, the
  # unrecognizable — is not rendered, and a rewrite dropping it is
  # something Store reports rather than a deletion it honors.
  def test_rendered_refuses_what_no_client_shows
    [property("1985-04"), property("1985"), property("--04"), property("---12"),
      property("1985-13"), property("--0432"), property("19850412"),
      property("banana"),
      property("--0412", group: "item1")].each do |unrendered|
      refute ProTacts::Birthday.rendered?(unrendered), unrendered.value
    end
  end
end
