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
  # a submitted one on write — the same split a group's shared attributes
  # take (docs/plans/2026-08-24-vcard-storage-and-groups.md), and the
  # full reasoning is docs/plans/2026-08-31-partial-birthdays.md.
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
    # date, the one deliberate loss the design records.
    FULL_DATE = /\A(\d{4})-(\d{2})-(\d{2})(?:T\d{2}:?\d{2}(:?\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?\z/ #: Regexp

    # The no-year shape macOS writes, with 1604 standing in for the year
    # in both the parameter and the value (docs/macos-contacts.md,
    # "Birthdays without a year"). 1604 because it is the first year of
    # the Gregorian calendar; the parameter names the year to omit.
    OMIT_YEAR_DATE = /\A1604-(\d{2})-(\d{2})\z/ #: Regexp
    OMIT_YEAR = "1604" #: String

    # A content line naming BDAY, optionally group-prefixed the way
    # macOS labels properties (`item1.BDAY`). A group's first physical
    # line is all that is matched; continuations travel with it.
    BDAY_LINE = /\A(?:[A-Za-z0-9-]+\.)?BDAY[;:]/i #: Regexp

    # The anchor compose inserts before, so the property lands inside
    # the envelope however bare the card is.
    END_LINE = /\AEND:VCARD/i #: Regexp

    # A physical line that continues the one above it (RFC 2426 section
    # 2.6 folding).
    CONTINUATION = /\A[ \t]/ #: Regexp

    # What subtract found in a card: the card to store, the birthday it
    # gave up, and whether a BDAY line is still in the card because no
    # modeled spelling would recompose it — the probe forms ride on
    # exactly that, served as stored.
    #
    # The signature lives in sig/pro_tacts/birthday.rbs with the class's.
    Split = Data.define(:card, :birthday, :bday_kept)

    # The only constructor, so no birthday exists in a shape the grammar
    # rejects. Components are not calendar-validated beyond their ranges:
    # a partial date has no whole date to be wrong about, and a nonsense
    # but well-shaped one round-trips rather than 500s a write.
    def self.new(year: nil, month: nil, day: nil)
      if year.nil? && month.nil? && day.nil?
        raise ArgumentError, "a birthday needs at least one of year, month, and day"
      end
      if year && month.nil? && day
        raise ArgumentError, "year with day but no month is not a shape RFC 6350 section 4.3.1 admits"
      end
      if month && !month.between?(1, 12)
        raise ArgumentError, "month out of range: #{month}"
      end
      if day && !day.between?(1, 31)
        raise ArgumentError, "day out of range: #{day}"
      end
      if year && !year.between?(0, 9999)
        raise ArgumentError, "year out of range: #{year}"
      end

      super
    end

    # The two wire forms a client has been verified to accept: a plain
    # full date, and Apple's 1604 sentinel for a month and day. The other
    # four shapes have no verified spelling and reach no client — this
    # returns nil for them and compose leaves the card alone.
    def to_line
      if year && month && day
        format("BDAY:%04d-%02d-%02d", year, month, day)
      elsif month && day
        format("BDAY;X-APPLE-OMIT-YEAR=1604:1604-%02d-%02d", month, day)
      end
    end

    # Whether any served card carries this birthday. The deletion rule
    # turns on it: a client that never saw the birthday cannot have
    # deleted it.
    def served?
      !to_line.nil?
    end

    # Reads one parsed BDAY property into the model, or nil for every
    # spelling the model does not recompose — which keeps it in the card
    # verbatim rather than losing it (RFC 6352 section 6.3.2.2). Only the
    # two forms compose emits are accepted, and only bare: any extra
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
    rescue ArgumentError
      # A component out of range is unmodeled, not exceptional: the line
      # stays in the card as it came.
      nil
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

    # Splits a submitted card into what gets stored and the birthday it
    # carried. One BDAY line in a modeled spelling moves into the model
    # and out of the card; any other BDAY — the vCard 4.0 forms, a
    # foreign sentinel, more than one — is data this model cannot
    # recompose and stays in the card byte for byte, with the
    # model emptied so compose never adds a second BDAY beside it.
    def self.subtract(card)
      # Bytes that are not the UTF-8 the store's contract promises are
      # never parsed — they pass through untouched to the bind that
      # refuses them, which is where the contract is enforced.
      unless card.valid_encoding?
        return Split.new(card:, birthday: nil, bday_kept: false)
      end

      bday_groups, other_groups = line_groups(card).partition { it.first.match?(BDAY_LINE) }

      birthday = nil
      if bday_groups.length == 1
        property = parse_line(bday_groups.fetch(0).join)
        birthday = property && from_property(property)
      end

      extracted = !birthday.nil?
      Split.new(
        card: extracted ? other_groups.join : card,
        birthday:,
        bday_kept: !extracted && !bday_groups.empty?,
      )
    end

    # Puts a birthday into a stored card, immediately before END:VCARD,
    # as the inverse of subtract. A birthday with no wire form, or none
    # at all, leaves the card exactly as it is. The inserted line takes
    # the END line's own terminator so a card stays single-convention;
    # with no END to anchor to there is no envelope worth respecting, and
    # the line is appended with CRLF.
    def self.compose(card, birthday)
      line = birthday && birthday.to_line
      return card if line.nil?

      lines = physical_lines(card)
      index = lines.rindex { it.match?(END_LINE) }
      if index
        lines.insert(index, line + terminator_of(lines.fetch(index)))
        lines.join
      else
        card + line + "\r\n"
      end
    end

    # One content line read as a property, or nil when it does not read
    # as one. The parser unfolds what it is handed, so a folded BDAY
    # arrives here as the single logical line it is.
    def self.parse_line(text)
      VCard::Parser.parse(text).fetch(0, nil)
    rescue VCard::ParseError
      nil
    end

    # Physical lines with their terminators attached, so surgery on them
    # cannot lose or normalize a line break.
    def self.physical_lines(card)
      card.split(/(?<=\n)/, -1)
    end

    # Logical lines: a physical line and the continuations folded under
    # it, kept together because a BDAY and its fold are one property.
    # Slicing before each non-continuation, rather than chunking, is
    # what attaches a continuation to the line above it.
    def self.line_groups(card)
      physical_lines(card).slice_when { |_line, next_line| !next_line.match?(CONTINUATION) }.to_a
    end

    # The line break a line ends with, for the line inserted beside it to
    # match. CRLF when it has none, being the grammar's own.
    def self.terminator_of(line)
      line[/\r?\n\z/] || "\r\n"
    end
  end
end
