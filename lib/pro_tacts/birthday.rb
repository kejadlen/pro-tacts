require "date"

require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  # A birthday as the app models it: a partial date, where any of year,
  # month, and day may be missing.
  #
  # The shape is RFC 6350 section 4.3.1's date grammar, which admits six
  # of the eight presence patterns: all three, year-month, year alone,
  # month-day, month alone, and day alone. Year-with-day and nothing-at-
  # all are not forms a date can take there, so the constructor refuses
  # them. Five of the six appear as examples in the vendored text; month
  # alone follows from its allowance of ISO 8601 truncated representation
  # f), which it references but does not spell out.
  #
  # vCard 3.0 cannot carry any of this: RFC 2425 section 5.8.4 defines
  # the date value as `date-fullyear ["-"] date-month ["-"] date-mday`
  # with all three components required, and RFC 2426 section 3.1.5 builds
  # BDAY on it. So a birthday is database state that no stored card
  # carries, composed into the served card on read and subtracted out of
  # a submitted one on write — Store owns that surgery, over the card
  # VCard reads and the property-level reading below; the full reasoning
  # is docs/plans/2026-08-31-partial-birthdays.md and
  # docs/plans/2026-09-01-birthdays-across-a-rewrite.md.
  #
  # The signature lives in sig/pro_tacts/birthday.rbs: a Data class has
  # no constant super class for the inline syntax to read.
  # @rbs skip
  class Birthday < Data.define(:year, :month, :day)
    # A full date, the one partial shape vCard 3.0 carries natively
    # (RFC 2425 section 5.8.4). The dashed form is what macOS writes;
    # the undashed one is legal too and deliberately unmodeled, so it
    # stays in a card verbatim rather than drift to this model's
    # spelling. The optional time is RFC 2426 section 3.1.5's other
    # value shape, and it is accepted and dropped: a birthday is a
    # date, the one deliberate loss the design records. Components in
    # range, so an out-of-range date does not match and stays in the
    # card rather than reaching a constructor that would refuse it.
    FULL_DATE = /\A(\d{4})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])(?:T\d{2}:?\d{2}(:?\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?\z/ #: Regexp

    # The no-year shape macOS writes, with 1604 standing in for the year
    # in both the parameter and the value (docs/macos-contacts.md,
    # "Birthdays without a year"). 1604 because it is the first year of
    # the Gregorian calendar; the parameter names the year to omit.
    # Components in range, like FULL_DATE.
    OMIT_YEAR_DATE = /\A1604-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])\z/ #: Regexp
    OMIT_YEAR = "1604" #: String

    # The BDAY values no client renders, one named pattern per shape —
    # dashed as RFC 6350 section 4.3.1's examples spell them,
    # components in range, each anchored alone so no edit to one can
    # loosen another's. Capturing, because #from_value reads the
    # components back; the predicate reads below only match, which
    # captures do not disturb. A value off the list is not carried
    # across a rewrite, by the same probe: the served shapes in any
    # spelling were visible, so their absence is a deletion, and an
    # unrecognized or out-of-range value is cleaner dying with the
    # rewrite than living forever (docs/macos-contacts.md, "A birthday
    # the client cannot render is dropped from the card").
    YEAR_AND_MONTH = /\A(\d{4})-(0[1-9]|1[0-2])\z/ #: Regexp
    YEAR_ALONE = /\A(\d{4})\z/ #: Regexp
    MONTH_ALONE = /\A--(0[1-9]|1[0-2])\z/ #: Regexp
    DAY_ALONE = /\A---(0[1-9]|[12]\d|3[01])\z/ #: Regexp

    UNRENDERED_VALUES = [
      YEAR_AND_MONTH,
      YEAR_ALONE,
      MONTH_ALONE,
      DAY_ALONE,
    ] #: Array[Regexp]

    # The reduced no-year values macOS reads on a card it did not write
    # and converts to the sentinel on its own
    # (docs/macos-contacts.md, "Birthdays without a year"). Together
    # with #from_property's two spellings this is the rendered set: a
    # BDAY a client could see, and so could have deleted. Capturing
    # for #from_value, like the unrendered patterns above.
    REDUCED_DATE = /\A--(0[1-9]|1[0-2])-?(0[1-9]|[12]\d|3[01])\z/ #: Regexp

    # The only constructor, so no birthday exists in a shape the grammar
    # rejects: one `in` clause per shape RFC 6350 section 4.3.1 admits,
    # each component's range standing where the component stands, so the
    # pattern is the grammar rather than a prose description of it. A
    # range admits any Comparable in its bounds, so the check is
    # Integer-grade only in practice: the two producers — SQLite's
    # integer columns and #to_i — cannot yield anything else, and a
    # String or nil-shaped miss falls to the else. Components are not
    # calendar-validated beyond their ranges: a partial date has no
    # whole date to be wrong about, and a nonsense but well-shaped one
    # round-trips rather than 500s a write.
    def self.new(year: nil, month: nil, day: nil)
      case [year, month, day]
      in [0..9999, 1..12, 1..31]
      in [0..9999, 1..12, nil]
      in [0..9999, nil, nil]
      in [nil, 1..12, 1..31]
      in [nil, 1..12, nil]
      in [nil, nil, 1..31]
      else
        raise ArgumentError,
          "not a shape RFC 6350 section 4.3.1 admits: year=#{year.inspect}, month=#{month.inspect}, day=#{day.inspect}"
      end

      super
    end

    # The two wire forms a client has been verified to accept: a plain
    # full date, and Apple's 1604 sentinel for a month and day. The other
    # four shapes have no verified spelling and reach no client — this
    # returns nil for them and no card grows a BDAY on their behalf.
    # UNRENDERED_VALUES is exactly those four shapes' spellings, so
    # widening this means narrowing that.
    def to_line
      case [year, month, day]
      in [Integer => y, Integer => m, Integer => d]
        format("BDAY:%04d-%02d-%02d", y, m, d)
      in [nil, Integer => m, Integer => d]
        format("BDAY;X-APPLE-OMIT-YEAR=1604:1604-%02d-%02d", m, d)
      else
        nil
      end
    end

    # The birthday in prose, one clause per shape the constructor
    # admits — the same six, in the same order — so every display of a
    # birthday agrees. Carries no calendar: the components were
    # range-checked when built, and Date.new would only add a way to
    # fail, on a value like February 30 that is impossible but
    # well-shaped and renders as the day it names. No else: the six are
    # every shape a Birthday holds, so a seventh is better raising here
    # than rendering as whichever clause it fell through to.
    def to_s
      case [year, month, day]
      in [Integer => y, Integer => m, Integer => d]
        "#{Date::MONTHNAMES[m]} #{d}, #{y}"
      in [Integer => y, Integer => m, nil]
        "#{Date::MONTHNAMES[m]} #{y}"
      in [Integer => y, nil, nil]
        y.to_s
      in [nil, Integer => m, Integer => d]
        "#{Date::MONTHNAMES[m]} #{d}"
      in [nil, Integer => m, nil]
        Date::MONTHNAMES[m].to_s
      in [nil, nil, Integer => d]
        d.to_s
      end
    end

    # Whether any served card carries this birthday. The deletion rule
    # turns on it: a client that never saw the birthday cannot have
    # deleted it.
    def served?
      !to_line.nil?
    end

    # Any well-shaped BDAY value as a model, regardless of spelling:
    # a full date (the optional time accepted and dropped, as
    # #from_property drops it), the reduced no-year, and the four
    # UNRENDERED_VALUES shapes — every form the grammar admits. A
    # display reader, the raw-value counterpart of #from_property: the
    # write path keeps reading properties, and accepts only what
    # #to_line can serve back, so what a client PUTs still recomposes
    # into exactly the served forms. A bare 1604 date is a full date
    # here, as it is there — the sentinel is the parameter's to claim.
    # Nil for anything else, and the caller keeps the value as stored.
    def self.from_value(value)
      if (m = value.match(FULL_DATE))
        new(year: m[1].to_i, month: m[2].to_i, day: m[3].to_i)
      elsif (m = value.match(REDUCED_DATE))
        new(month: m[1].to_i, day: m[2].to_i)
      elsif (m = value.match(YEAR_AND_MONTH))
        new(year: m[1].to_i, month: m[2].to_i)
      elsif (m = value.match(YEAR_ALONE))
        new(year: m[1].to_i)
      elsif (m = value.match(MONTH_ALONE))
        new(month: m[1].to_i)
      elsif (m = value.match(DAY_ALONE))
        new(day: m[1].to_i)
      end
    end

    # Reads one parsed BDAY property into the model, or nil for every
    # spelling the model does not recompose — which keeps it in the card
    # verbatim rather than losing it (RFC 6352 section 6.3.2.2). Only the
    # two forms #to_line emits are accepted, and only bare: any extra
    # parameter travels with the line, so a line carrying one is left
    # whole. A grouped `item1.BDAY` likewise stays, because its label
    # pairing belongs to the card.
    def self.from_property(property)
      return nil if property.group

      if property.parameters.empty? && (m = property.value.match(FULL_DATE))
        new(year: m[1].to_i, month: m[2].to_i, day: m[3].to_i)
      elsif apple_no_year?(property) && (m = property.value.match(OMIT_YEAR_DATE))
        new(month: m[1].to_i, day: m[2].to_i)
      end
    end

    # The parameter half of the Apple form, exactly: the one parameter,
    # named for the year it stands in. A different sentinel or a value
    # disagreeing with the year in the date is not the verified form and
    # is not claimed.
    def self.apple_no_year?(property)
      return false unless property.parameters.length == 1

      name, value = property.parameters.fetch(0)
      name.casecmp?("X-APPLE-OMIT-YEAR") && value == OMIT_YEAR
    end

    # Whether a BDAY value is one no client renders — the spellings a
    # rewrite carries across, so the birthday survives a client that
    # drops what it cannot display. A predicate rather than a reader:
    # nothing downstream wants the shape as a model, and a whitelist
    # cannot raise on what it does not recognize.
    def self.unrendered_value?(value)
      UNRENDERED_VALUES.any? { value.match?(it) }
    end

    # Whether a client renders this BDAY property as a birthday: one of
    # the two spellings #to_line emits (#from_property reads exactly
    # those), or a reduced no-year value macOS additionally reads. A
    # client that renders a BDAY can have deleted it, so its absence
    # from a rewrite is a removal; a property that is neither rendered
    # nor carried is neither, and the rewrite that drops it reports
    # the loss — Store#put, to Sentry.
    def self.rendered?(property)
      !from_property(property).nil? ||
        (property.group.nil? && property.parameters.empty? && property.value.match?(REDUCED_DATE))
    end
  end
end
