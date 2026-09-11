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
  # Every well-shaped BDAY a client sends is read into this model, and
  # only the two shapes that survive a round trip through both Apple
  # clients go back out (#to_line); the other four are kept and shown
  # but never sent. Store moves the line out of the card and composes it
  # back in. The reasoning is docs/plans/2026-09-11-every-birthday-in-the-model.md;
  # why a partial date cannot live in a vCard 3.0 card is
  # docs/plans/2026-08-31-partial-birthdays.md.
  #
  # The signature lives in sig/pro_tacts/birthday.rbs: a Data class has
  # no constant super class for the inline syntax to read.
  # @rbs skip
  class Birthday < Data.define(:year, :month, :day)
    # The year Apple writes in place of a missing one. It means "no year"
    # wherever it appears, parameter or not, because iOS writes the
    # sentinel back without its parameter (docs/apple-contacts.md, "iOS
    # writes a birthday it cannot hold as a date it made up").
    NO_YEAR = 1604 #: Integer
    OMIT_YEAR = "1604" #: String

    # The BDAY values this reads, one pattern per spelling, components
    # in range so an out-of-range value does not match and stays in the
    # card rather than reaching a constructor that would refuse it.
    #
    # A full date is dashed, as both clients write it; the undashed form
    # RFC 2425 section 5.8.4 also allows is not read. The optional time
    # is RFC 2426 section 3.1.5's other value shape, accepted and dropped:
    # a birthday is a date.
    FULL_DATE = /\A(\d{4})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])(?:T\d{2}:?\d{2}(:?\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?\z/ #: Regexp
    # The rest are RFC 6350 section 4.3.1's reduced and truncated forms,
    # the month-day in both the basic and extended spelling.
    MONTH_AND_DAY = /\A--(0[1-9]|1[0-2])-?(0[1-9]|[12]\d|3[01])\z/ #: Regexp
    YEAR_AND_MONTH = /\A(\d{4})-(0[1-9]|1[0-2])\z/ #: Regexp
    YEAR_ALONE = /\A(\d{4})\z/ #: Regexp
    MONTH_ALONE = /\A--(0[1-9]|1[0-2])\z/ #: Regexp
    DAY_ALONE = /\A---(0[1-9]|[12]\d|3[01])\z/ #: Regexp

    # The value X-APPLE-OMIT-YEAR is allowed on: the sentinel date alone,
    # no time, as macOS writes it (docs/apple-contacts.md, "Birthdays
    # without a year").
    OMIT_YEAR_DATE = /\A1604-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])\z/ #: Regexp

    # The only constructor, so no birthday exists in a shape the grammar
    # rejects: one `in` clause per shape RFC 6350 section 4.3.1 admits,
    # each component's range standing where the component stands. A range
    # admits any Comparable in its bounds, but the two producers — SQLite's
    # integer columns and #to_i — only yield Integers, and a String misses
    # to the else. Components are not calendar-validated: a nonsense but
    # well-shaped date round-trips rather than 500s a write.
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

    # The line sent to clients: a plain full date, or Apple's 1604
    # sentinel for a month and day. Nil for the other four shapes, which
    # no client displays, so no served card carries them.
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
    # admits, so every display of a birthday agrees. No calendar: Date.new
    # would only add a way to fail on a well-shaped February 30. No else:
    # the six are every shape a Birthday holds.
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

    # Whether served cards carry this birthday. A client that was never
    # sent a birthday cannot have deleted it (Store#put).
    def served?
      !to_line.nil?
    end

    # One parsed BDAY property as a birthday, or nil for a line the model
    # does not take — which then stays in the card verbatim (RFC 6352
    # section 6.3.2.2). A grouped `item1.BDAY` is not taken, because its
    # label pairing belongs to the card, and neither is any parameter but
    # VALUE=date and the Apple sentinel's.
    def self.from_property(property)
      return nil if property.group

      parameters = significant_parameters(property)
      if parameters.empty? || (apple_no_year?(parameters) && property.value.match?(OMIT_YEAR_DATE))
        from_value(property.value)
      end
    end

    # A BDAY's parameters without VALUE=date, which names the default
    # value type (RFC 2426 section 3.1.5) and so says nothing the bare
    # line does not. iOS spells it out on every birthday it writes.
    def self.significant_parameters(property)
      property.parameters.reject { |name, value| name.casecmp?("VALUE") && value.casecmp?("date") }
    end

    # The Apple sentinel's parameter, exactly: the one parameter, naming
    # 1604 as the year to omit.
    def self.apple_no_year?(parameters)
      return false unless parameters.length == 1

      name, value = parameters.fetch(0)
      name.casecmp?("X-APPLE-OMIT-YEAR") && value == OMIT_YEAR
    end

    # A BDAY value in any spelling this reads, or nil.
    def self.from_value(value)
      if (m = value.match(FULL_DATE))
        year = m[1].to_i
        month = m[2].to_i
        day = m[3].to_i
        year == NO_YEAR ? new(month:, day:) : new(year:, month:, day:)
      elsif (m = value.match(MONTH_AND_DAY))
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
    private_class_method :from_value, :apple_no_year?
  end
end
