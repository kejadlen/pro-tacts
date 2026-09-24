require "sentry-ruby"

require "pro_tacts/birthday"
require "pro_tacts/birthday_line"
require "pro_tacts/contact"
require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  # A card a client submitted over a contact, read back into what the
  # store keeps: the card to store, the birthday to hold beside it, and
  # what the member's edits to its groups' lines ask of those groups.
  # The inverse of what Contact composes — served is stored plus
  # inherited plus birthday, so stored is submitted minus both
  # (docs/plans/2026-08-31-partial-birthdays.md,
  # docs/plans/2026-08-24-vcard-storage-and-groups.md).
  #
  # An edit of a contact rather than a kind of one: the contact after
  # the write is Store#put's to compose, because the group edits move
  # the very groups `before` holds, and a card a client creates can
  # join `sync:*` on the way in. Nothing here reads or writes the
  # database; the reports go to Sentry from here because this is the
  # arrival (AGENTS.md, "The one exception is the arrival reports").
  #
  # GroupEdit's signature is in sig/pro_tacts/edited_contact.rbs, it
  # being a Data class.
  class EditedContact
    # @rbs @before: Contact?
    # @rbs @submitted: VCard
    # @rbs @stored: VCard
    # @rbs @birthday: Birthday?
    # @rbs @group_edits: Array[GroupEdit]

    # What one classified line asks of the group it came from: the row
    # to write, and the line that replaces it — or nil to remove the
    # row, which is what a member's deletion of a shared line means
    # (docs/plans/2026-09-09-group-edits-propagate.md, "The open
    # question, decided").
    # @rbs skip
    GroupEdit = Data.define(:group_id, :position, :line)

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

    # `before` is the contact this write replaces, nil for one being
    # created: its stored card, its birthday, and the lines its groups
    # lend it are what the submission is read against.
    #: (VCard submitted, before: Contact?) -> void
    def initialize(submitted, before:)
      @before = before
      @submitted = submitted
      @birthday, rest = split_birthday
      @stored, @group_edits = subtract_inherited(rest)
    end

    attr_reader :before

    attr_reader :submitted

    # The card to store: the submission minus its birthday and minus
    # what its groups lend it.
    attr_reader :stored

    # The model's new birthday, or nil to empty the model.
    attr_reader :birthday

    # The group rows the member's edits rewrite or remove, empty where
    # every lent line came back untouched.
    attr_reader :group_edits

    private

    # The card as it stood before this write, nil for one being created.
    #: () -> VCard?
    def stored_before
      @before&.stored
    end

    # The birthday half (docs/plans/2026-09-11-every-birthday-in-the-model.md):
    # the model's new birthday, and the card to store beside it. A card
    # holds at most one BDAY, and one that reads as a birthday leaves
    # the card for the model. Any other stays in the card byte for
    # byte, reported, with the model emptied so nothing composes a
    # second BDAY beside it (RFC 6352 section 6.3.2.2).
    #
    # No BDAY is a client that was sent the birthday removing it, or
    # one that was never sent it and so cannot have. A BDAY line left
    # in the stored card goes with the write, which is worth saying.
    #
    # case/when rather than case/in, BirthdayLine's own rule: Steep
    # does not check the bodies of case/in branches, and these are the
    # ones worth checking — which is what the last arm is for.
    #: () -> [Birthday?, VCard]
    def split_birthday
      bdays, rest = @submitted.extract("BDAY")
      if bdays.empty?
        report_lost_bday_lines
        existing = @before&.birthday
        return [existing && !existing.served? ? existing : nil, @submitted]
      end

      if bdays.length > 1
        report_many_bday_lines(bdays.length)
        return [nil, @submitted]
      end

      line = BirthdayLine.read(bdays.fetch(0))
      case line
      when BirthdayLine::Modeled
        [line.birthday, rest]
      when BirthdayLine::Unrecognized
        report_unrecognized_bday_line
        [nil, @submitted]
      when BirthdayLine::Unreadable
        [nil, @submitted]
      else
        raise "no arm for #{line.class}"
      end
    end

    # The arrival report: a BDAY the model does not take is unexpected
    # input, and storing it verbatim would be the last anyone heard of
    # it. The message carries no card content
    # (the line config.ru draws for Sentry); the value stays on the
    # machine, where the admin view shows it raw.
    #: () -> void
    def report_unrecognized_bday_line
      Sentry.capture_message("a submitted card carried a BDAY line the model does not take", level: :warning)
    end

    # A contact has one birthday, so a card with several cannot say
    # which it means, whatever each line holds.
    #: (Integer count) -> void
    def report_many_bday_lines(count)
      Sentry.capture_message("a submitted card carried #{count} BDAY lines", level: :warning)
    end

    # The loss report, the write's half of the arrival one: a BDAY line
    # still in the stored card is one the model did not take, and a
    # write without it is about to drop it with nobody told.
    #: () -> void
    def report_lost_bday_lines
      stored = stored_before
      return if stored.nil?

      lines, = stored.extract("BDAY")
      return if lines.empty?

      Sentry.capture_message("a write dropped #{lines.length} BDAY line(s) the model did not take", level: :warning)
    end

    # The card with the lines its groups lend it taken back out: served
    # is stored plus inherited, so stored is submitted minus inherited
    # and a client that PUTs back what it downloaded stores what it
    # started with (docs/plans/2026-08-24-vcard-storage-and-groups.md,
    # "Groups compose into cards"). Which of four shapes a lent line
    # came back as, and what each asks of its group, is #classify —
    # argued in that plan's "Classifying what came back" and in
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
    #: (VCard vcard) -> [VCard, Array[GroupEdit]]
    def subtract_inherited(vcard)
      lent = @before&.inherited || [] #: Array[Contact::Inherited]
      return [vcard, []] if lent.empty?

      unaccounted = unaccounted_lines(vcard)
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

      edits = [] #: Array[GroupEdit]
      ambiguous = 0
      unshareable = 0
      moved.each do |row|
        case classify(row, unaccounted, taken)
        in GroupEdit => edit then edits << edit
        in :ambiguous then ambiguous += 1
        in :unshareable then unshareable += 1
        end
      end

      report_ambiguous_inherited_lines(ambiguous)
      report_unshareable_lines(unshareable)
      [taken.reduce(vcard) { |rest, line| rest.substitute(line.digest, []) }, edits]
    end

    # What a lent line that came back changed asks of its group: the
    # edit the one candidate of its name is, or the deletion no
    # candidate at all is. The two refusals ask nothing — more than one
    # candidate cannot be attributed, and a candidate the group could
    # not hold must not be tried (#shareable?) — and both leave the
    # line in the member's own card, where an edit at least is not
    # lost.
    #
    # An edit's line is struck from the pool and carried by the group
    # from here on, so `taken` grows the way it does for an untouched
    # one.
    #: (Contact::Inherited row, Array[VCard::Parser::Line] unaccounted, Array[VCard::Parser::Line] taken) -> (GroupEdit | :ambiguous | :unshareable)
    def classify(row, unaccounted, taken)
      candidates = unaccounted.select { it.names?(property_name(row.line)) }
      return GroupEdit.new(group_id: row.group.id, position: row.position, line: nil) if candidates.empty?
      return :ambiguous unless candidates.length == 1

      edited = candidates.fetch(0)
      return :unshareable unless shareable?(edited)

      taken << strike(unaccounted, edited)
      GroupEdit.new(group_id: row.group.id, position: row.position, line: edited.content)
    end

    # The line out of the pool, so no second lent line is attributed
    # it. `index` rather than `delete`, which would take every copy of
    # a line a card carries twice.
    #: (Array[VCard::Parser::Line] unaccounted, VCard::Parser::Line line) -> VCard::Parser::Line
    def strike(unaccounted, line)
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
    def shareable?(line)
      property = line.property
      return false if property.nil?

      property.group.nil? && SHAREABLE_NAMES.include?(property.name.upcase)
    end

    # A lent line as the parser reads it: one logical line, the group
    # schema admitting no other shape (db/migrations/004_groups.rb).
    #: (String line) -> VCard::Parser::Line
    def parsed_line(line)
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
    def unedited?(line, lent, pool)
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
    def kept_types?(line, lent, pool)
      label = label_of(line, pool)&.property
      types = types_of(line)
      types = (types + [label.text.downcase]).uniq.sort if label
      types == types_of(lent)
    end

    # The `X-ABLabel` sharing a property group with `line`, the other
    # half of the pair #kept_types? reads as one. Nil for an ungrouped
    # line, or a group the pool holds no label for.
    #: (VCard::Parser::Line line, Array[VCard::Parser::Line] pool) -> VCard::Parser::Line?
    def label_of(line, pool)
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
    def value_of(line)
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
    def types_of(line)
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
    #: (VCard vcard) -> Array[VCard::Parser::Line]
    def unaccounted_lines(vcard)
      stored = stored_before&.lines&.map { it.verbatim.chomp } || [] #: Array[String]
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
    def property_name(line)
      line[/\A[^;:]*/].to_s
    end

    # The ambiguity report: a lent line that came back as neither its
    # own bytes nor a single candidate is one this server cannot
    # attribute — two lines of that name arrived that the member's card
    # does not explain, and calling either the edit would be a guess.
    # The card is stored as it arrived and the line is news, the same
    # bargain report_unrecognized_bday_line makes.
    #: (Integer count) -> void
    def report_ambiguous_inherited_lines(count)
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
    # `X-ABLabel` beside it (#kept_types?), and the news is worth
    # having because that member now serves the line twice — its own
    # copy and the group's — until someone reconciles them.
    #: (Integer count) -> void
    def report_unshareable_lines(count)
      return if count.zero?

      Sentry.capture_message(
        "a submitted card edited #{count} inherited line(s) into a shape no group may hold",
        level: :warning,
      )
    end
  end
end
