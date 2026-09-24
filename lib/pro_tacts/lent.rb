require "sentry-ruby"

require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  # One line a group lends one card, with the row it is lent from —
  # the write path's reading of what Store#inherited_of answers as the
  # model's. A member's edit has to reach the group_properties row the
  # line came from, which takes the position as well as the group.
  #
  # The signature lives in sig/pro_tacts/lent.rbs, this being a Data
  # class.
  # @rbs skip
  Lent = Data.define(:group_id, :position, :line)

  # Reopened rather than defined in the block above, for the reason
  # VCard::Parser::Property is.
  class Lent
    # What one classified line asks of the group it came from: the row
    # to write, and the line that replaces it — or nil to remove the
    # row, which is what a member's deletion of a shared line means
    # (docs/plans/2026-09-09-group-edits-propagate.md, "The open
    # question, decided").
    # @rbs skip
    Edit = Data.define(:group_id, :position, :line)

    # The property names whose value is structured rather than free
    # text (RFC 2426 section 3.2.1), among the two a group may lend:
    # ADR is components, NOTE is text (db/migrations/004_groups.rb).
    # Which reading applies is the caller's to know — the parser holds
    # no value types — and this is the one caller that compares values.
    STRUCTURED_VALUES = %w[ADR].freeze #: Array[String]

    # The property names a group may lend, a second copy of the CHECK
    # in db/migrations/004_groups.rb and saying so here. The constraint
    # stays the authority; this is the pre-check a propagated edit
    # passes first, so that a line the group cannot hold is refused
    # rather than raising on an ordinary sync
    # (docs/plans/2026-09-09-group-edits-propagate.md, "The line a
    # group cannot hold").
    SHAREABLE_NAMES = %w[ADR NOTE].freeze #: Array[String]

    # The submitted card with the lines its groups lend it taken back
    # out, and the edits the lines that came back changed ask of those
    # groups: served is stored plus inherited, so stored is submitted
    # minus inherited and a client that PUTs back what it downloaded
    # stores what it started with
    # (docs/plans/2026-08-24-vcard-storage-and-groups.md, "Groups
    # compose into cards"). Which of four shapes a lent line came back
    # as, and what each asks of its group, is .classify — argued in
    # that plan's "Classifying what came back" and in
    # docs/plans/2026-09-09-group-edits-propagate.md.
    #
    # Two passes, because one lent line must not be attributed a line
    # another lent line would have matched exactly. A member of two
    # groups that each lend an address, editing one of them, submits
    # one edited address and one untouched: walked in a single pass,
    # whichever group came first would read the other's untouched line
    # as its own edit and the other would read a deletion. Every
    # untouched line is struck first, and only what is left is
    # attributed.
    #
    # #substitute rather than #extract and #insert, which would move a
    # member's own lines of the same name to the card's end: the lines
    # this leaves keep their positions, so a submission that was the
    # served card round-trips to the bytes it was composed from and the
    # PUT can answer with a strong etag (RFC 6352 section 6.3.2.3).
    #: (VCard vcard, Array[Lent] lent, VCard? stored_before) -> [VCard, Array[Edit]]
    def self.subtract(vcard, lent, stored_before)
      return [vcard, []] if lent.empty?

      unaccounted = unaccounted_lines(vcard, stored_before)
      taken = [] #: Array[VCard::Parser::Line]

      moved = lent.reject { |row|
        candidates = unaccounted.select { it.names?(property_name(row.line)) }
        # Blind to lines saying the same thing the way the editor's
        # digests are blind to identical bytes
        # (VCard::Parser::Line#digest): where a member's own card
        # carries what its group lends, which copy this takes is
        # undecidable and their saying the same thing makes it not
        # matter.
        match = candidates.find { unedited?(it, parsed_line(row.line), unaccounted) }
        if match
          label = label_of(match, unaccounted)
          taken << strike(unaccounted, match)
          taken << strike(unaccounted, label) if label
        end
        match
      }

      edits = [] #: Array[Edit]
      ambiguous = 0
      unshareable = 0
      moved.each do |row|
        case classify(row, unaccounted, taken)
        in Edit => edit then edits << edit
        in :ambiguous then ambiguous += 1
        in :unshareable then unshareable += 1
        end
      end

      report_ambiguous(ambiguous)
      report_unshareable(unshareable)
      [taken.reduce(vcard) { |rest, line| rest.substitute(line.digest, []) }, edits]
    end

    # What a lent line that came back changed asks of its group: the
    # edit the one candidate of its name is, or the deletion no
    # candidate at all is. The two refusals ask nothing — more than one
    # candidate cannot be attributed, and a candidate the group could
    # not hold must not be tried (.shareable?) — and both leave the
    # line in the member's own card, where an edit at least is not
    # lost.
    #
    # An edit's line is struck from the pool and carried by the group
    # from here on, so `taken` grows the way it does for an untouched
    # one.
    #: (Lent row, Array[VCard::Parser::Line] unaccounted, Array[VCard::Parser::Line] taken) -> (Edit | :ambiguous | :unshareable)
    def self.classify(row, unaccounted, taken)
      candidates = unaccounted.select { it.names?(property_name(row.line)) }
      return Edit.new(group_id: row.group_id, position: row.position, line: nil) if candidates.empty?
      return :ambiguous unless candidates.length == 1

      edited = candidates.fetch(0)
      return :unshareable unless shareable?(edited)

      taken << strike(unaccounted, edited)
      Edit.new(group_id: row.group_id, position: row.position, line: edited.content)
    end

    # The line out of the pool, so no second lent line is attributed
    # it. `index` rather than `delete`, which would take every copy of
    # a line a card carries twice.
    #: (Array[VCard::Parser::Line] unaccounted, VCard::Parser::Line line) -> VCard::Parser::Line
    def self.strike(unaccounted, line)
      unaccounted.delete_at(
        unaccounted.index(line) #: Integer
      )
      line
    end

    # Whether a group could hold this line: one of the names
    # SHAREABLE_NAMES admits, and no property group in front of it —
    # the CHECK's two clauses, read off the parse rather than matched
    # as bytes. A line that would not read is not one to share.
    #: (VCard::Parser::Line line) -> bool
    def self.shareable?(line)
      property = line.property
      return false if property.nil?

      property.group.nil? && SHAREABLE_NAMES.include?(property.name.upcase)
    end

    # A lent line as the parser reads it: one logical line, the group
    # schema admitting no other shape (db/migrations/004_groups.rb).
    #: (String line) -> VCard::Parser::Line
    def self.parsed_line(line)
      VCard.new(line).lines.fetch(0)
    end

    # Whether a submitted line still says what the group lends, which
    # is a question about what it says and not about its bytes: macOS
    # re-serializes every card it touches
    # (docs/apple-contacts.md, "The client rewrites every card it
    # touches"), and comparing bytes reads every such line as an edit.
    #
    # What a line says is its value and its types, because a relabel is
    # an edit the group takes like any other
    # (docs/plans/2026-08-24-vcard-storage-and-groups.md, "Edits
    # propagate to the group"). Every other parameter goes uncompared,
    # being the half the client rewrites unasked — it drops the ones it
    # does not model and fills in defaults on the ones it does.
    #
    # A line that will not read has no value to compare and falls back
    # to its bytes, which still recognize the line nobody touched.
    #: (VCard::Parser::Line line, VCard::Parser::Line lent, Array[VCard::Parser::Line] pool) -> bool
    def self.unedited?(line, lent, pool)
      value = value_of(lent)
      return line.verbatim.chomp == lent.verbatim.chomp if value.nil?

      value_of(line) == value && kept_types?(line, lent, pool)
    end

    # Whether a submitted line carries the types the group lent it,
    # across the three rewrites they survive. Two are cosmetic and
    # Property#types already absorbs them: the values come back
    # uppercased, and `pref` comes back filled in.
    #
    # The third moves the type off the line: a type Contacts has no
    # field for comes back as an `X-ABLabel` in a property group
    # (docs/apple-contacts.md, "An address type the client cannot
    # model becomes a custom label"), so that label counts as one of
    # the line's types and `ADR;TYPE=dom` coming back as `item1.ADR`
    # with `item1.X-ABLabel:dom` is unedited.
    #: (VCard::Parser::Line line, VCard::Parser::Line lent, Array[VCard::Parser::Line] pool) -> bool
    def self.kept_types?(line, lent, pool)
      label = label_of(line, pool)&.property
      types = types_of(line)
      types = (types + [label.text.downcase]).uniq.sort if label
      types == types_of(lent)
    end

    # The `X-ABLabel` sharing a property group with `line`, the other
    # half of the pair .kept_types? reads as one. Nil for an ungrouped
    # line, or a group the pool holds no label for.
    #: (VCard::Parser::Line line, Array[VCard::Parser::Line] pool) -> VCard::Parser::Line?
    def self.label_of(line, pool)
      group = line.property&.group
      return if group.nil?

      pool.find { |other|
        property = other.property
        !property.nil? && property.group&.casecmp?(group) == true && property.name.casecmp?("X-ABLABEL")
      }
    end

    # What a line says, as the reading its property's value type calls
    # for: an ADR compares component by component (RFC 2426 section
    # 3.2.1) and a NOTE as its unescaped text (section 2.4.2). Nil for
    # a line that would not read, which has no value at all.
    #: (VCard::Parser::Line line) -> Array[String]?
    def self.value_of(line)
      property = line.property
      return nil if property.nil?

      STRUCTURED_VALUES.include?(property.name.upcase) ? property.components : [property.text]
    end

    # A line's TYPE values as the set the round trip preserves, sorted
    # because `TYPE=home;TYPE=pref` and `TYPE=pref,home` are one thing
    # (RFC 2426 section 3.2.1, which the parser reads into pairs either
    # way). Empty for a line that would not read, which has no
    # parameters to compare.
    #: (VCard::Parser::Line line) -> Array[String]
    def self.types_of(line)
      property = line.property
      return [] if property.nil?

      property.types.sort
    end

    # The submission's lines the card as it stood before this write
    # does not already explain — one struck per stored line of the same bytes,
    # so a card that stores one of something and submits two leaves one
    # over. What is left is what the groups lent plus whatever the
    # client wrote beside it, which is the pool a lent line is
    # attributed from. Everything for a card being created, which has
    # no stored lines to explain anything.
    #: (VCard vcard, VCard? stored_before) -> Array[VCard::Parser::Line]
    def self.unaccounted_lines(vcard, stored_before)
      stored = stored_before ? stored_before.lines.map { it.verbatim.chomp } : [] #: Array[String]
      vcard.lines.reject { |line|
        index = stored.index(line.verbatim.chomp)
        stored.delete_at(index) if index
        index
      }
    end

    # A content line's property name: what stands before its first
    # parameter or its value (RFC 2426 section 2.1.1). Read off the
    # bytes rather than parsed, because the only lines asked are a
    # group's, which carry no `item1.` prefix to strip — the schema
    # refuses one (db/migrations/004_groups.rb).
    #: (String line) -> String
    def self.property_name(line)
      line[/\A[^;:]*/].to_s
    end

    # The ambiguity report: a lent line that came back as neither its
    # own bytes nor a single candidate is one this server cannot
    # attribute — two lines of that name arrived that the member's card
    # does not explain, and calling either the edit would be a guess.
    # The card is stored as it arrived and the line is news, the same
    # bargain BirthdayLine.report_unrecognized makes.
    #: (Integer count) -> void
    def self.report_ambiguous(count)
      return if count.zero?

      Sentry.capture_message(
        "a submitted card left #{count} inherited line(s) with more than one line of that name to attribute them to",
        level: :warning,
      )
    end

    # The refusal report: a member edited a shared line into a shape no
    # group may hold, so the edit stays on the member and the group
    # keeps what it lent. The known cause is an edit that lands in a
    # type Contacts cannot model — a relabel to one, or a new value
    # under one — which comes back as a property group with an
    # `X-ABLabel` beside it (.kept_types?), and the news is worth
    # having because that member now serves the line twice — its own
    # copy and the group's — until someone reconciles them.
    #: (Integer count) -> void
    def self.report_unshareable(count)
      return if count.zero?

      Sentry.capture_message(
        "a submitted card edited #{count} inherited line(s) into a shape no group may hold",
        level: :warning,
      )
    end

    private_class_method :classify, :strike, :shareable?, :parsed_line, :unedited?, :kept_types?, :label_of,
                         :value_of, :types_of, :unaccounted_lines, :property_name, :report_ambiguous,
                         :report_unshareable
  end
end
