require "sentry-ruby"

require "pro_tacts/birthday"
require "pro_tacts/birthday_line"
require "pro_tacts/contact"
require "pro_tacts/note_sections"
require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  # A card a client submitted over a contact, read back into what the
  # store keeps: the card to store, the birthday to hold beside it, the
  # addresses and note the contact's own entity holds, and what the
  # member's edits to its groups' components ask of those groups. The
  # inverse of what Contact composes — served is stored plus components
  # plus lent plus birthday, so stored and components are submitted
  # minus both (docs/plans/2026-08-31-partial-birthdays.md,
  # docs/plans/2026-10-25-contacts-on-entities.md).
  #
  # An edit of a contact rather than a kind of one: the contact after
  # the write is Store#put's to compose, because the group edits move
  # the very groups `before` holds, and a card a client creates can
  # join `sync:*` on the way in. Nothing here reads or writes the
  # database; the reports go to Sentry from here because this is the
  # arrival (AGENTS.md, "The one exception is the arrival reports").
  #
  # AddressEdit, NoteEdit, and Decomposed's signatures are in
  # sig/pro_tacts/edited_contact.rbs, them being Data classes.
  class EditedContact
    # @rbs @before: ContactDetails?
    # @rbs @submitted: VCard
    # @rbs @decomposed: Decomposed

    # What one classified address asks of the group it came from: the
    # row position to write, and the address that replaces it — or nil
    # to remove the row, which is what a member's deletion of a shared
    # address means (docs/plans/2026-09-09-group-edits-propagate.md,
    # "The open question, decided"). A label is part of the address, so
    # a member's relabel of a lent address reaches the group with the
    # value, whatever `item` spelling the client sent it under
    # (docs/plans/2026-10-25-contacts-on-entities.md, "Matching what
    # comes back").
    # @rbs skip
    AddressEdit = Data.define(:group_id, :position, :address)

    # What the submitted note asks of one lending group: the text to
    # write, or nil to remove the group's note — the note's row being
    # one, no position to name it by.
    # @rbs skip
    NoteEdit = Data.define(:group_id, :text)

    # The submission taken back apart: the card to store, minus its
    # birthday and minus everything its entity holds as components; the
    # model's new birthday, or nil to empty the model; the addresses
    # and note its own entity holds, replaced wholesale by what came
    # back unclaimed, in submission order; and the group rows the
    # member's edits rewrite or remove, empty where every lent address
    # and note came back untouched.
    # @rbs skip
    Decomposed = Data.define(
      :stored,
      :birthday,
      :addresses,
      :note,
      :address_edits,
      :note_edits,
    )

    # `before` is the contact this write replaces, nil for one being
    # created: its stored card, its birthday, and the components its
    # groups lend it are what the submission is read against.
    #: (VCard submitted, before: ContactDetails?) -> void
    def initialize(submitted, before:)
      @before = before
      @submitted = submitted
    end

    attr_reader :before

    attr_reader :submitted

    # The submission taken back apart, worked out on first ask and
    # kept, so the arrival reports go to Sentry once however often it
    # is read.
    #: () -> Decomposed
    def decomposed
      return @decomposed if defined?(@decomposed)

      markers, card = take_markers(@submitted)
      birthday, rest = split_birthday(card)
      stale = stale_groups(markers)
      report_stale_groups(stale.length)
      rest, address_edits = subtract_lent_addresses(rest, stale)
      rest, note_edits = subtract_lent_notes(rest, stale)
      addresses, stored = Contact.take_addresses(rest)
      note, stored = Contact.take_note(stored)
      @decomposed = Decomposed.new(
        stored:,
        birthday:,
        addresses:,
        note:,
        address_edits:,
        note_edits:,
      )
    end

    private

    # The card as it stood before this write, nil for one being created.
    #: () -> VCard?
    def stored_before
      @before&.stored
    end

    # The submission's X-PT-LENT lines as the version each names,
    # keyed by the group label that names it, and the card without
    # them: the reading half of Lent#marker_line, split on the value's
    # last colon, a label being a person's words and the version hex.
    # The marker is composed like the lines it versions and never
    # stored (docs/plans/2026-11-03-a-version-marker-guards-lent-
    # lines.md, "Arrival"), and a line that will not read is no marker
    # at all — the group reads as one never sent current lines, the
    # safe reading.
    #: (VCard vcard) -> [Hash[String, String], VCard]
    def take_markers(vcard)
      taken, card = vcard.extract(ContactDetails::LENT_MARKER)
      markers = taken.filter_map { |line|
        text = line.property&.text
        next if text.nil?

        label, colon, version = text.rpartition(":")
        [label, version] unless colon.empty?
      }.to_h
      [markers, card]
    end

    # The lending groups a submission may not edit: those it carries
    # no current marker for. A card composed by this server carries
    # the marker naming the version of each group's rows it was sent,
    # so a current marker is a client that downloaded what it submits
    # against and may delete or edit what it was sent — and an absent,
    # stale, or unreadable one is a card composed from something else,
    # whose missing lines cannot be read as deletions. The set holds
    # group ids, what an edit addresses a group by
    # (docs/plans/2026-11-03-a-version-marker-guards-lent-lines.md,
    # "The guard").
    #: (Hash[String, String] markers) -> Set[String]
    def stale_groups(markers)
      Set.new((@before&.lent || []).filter_map { |row|
        row.group.id if markers[row.group.label] != row.version
      })
    end

    # The refusal report, the one the incident lacked: the wipe was
    # silent, a successful PUT leaving no exchange entry
    # (docs/plans/2026-09-13-failed-exchanges-only.md) and the deletion
    # path raising nothing. The count carries no card content.
    #: (Integer count) -> void
    def report_stale_groups(count)
      return if count.zero?

      Sentry.capture_message(
        "a submitted card was not composed from the current lines of #{count} of its groups; nothing was attributed to them",
        level: :warning,
      )
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
    #: (VCard card) -> [Birthday?, VCard]
    def split_birthday(card)
      bdays, rest = card.extract("BDAY")
      if bdays.empty?
        report_lost_bday_lines
        existing = @before&.birthday
        return [existing && !existing.served? ? existing : nil, card]
      end

      if bdays.length > 1
        report_many_bday_lines(bdays.length)
        return [nil, card]
      end

      line = BirthdayLine.read(bdays.fetch(0))
      case line
      when BirthdayLine::Modeled
        [line.birthday, rest]
      when BirthdayLine::Unrecognized
        report_unrecognized_bday_line
        [nil, card]
      when BirthdayLine::Unreadable
        [nil, card]
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

    # The card with the addresses its groups lend it taken back out,
    # and what each edit asks of its group
    # (docs/plans/2026-10-25-contacts-on-entities.md, "Matching what
    # comes back").
    #
    # Two passes, because one lent address must not be attributed a
    # line another lent address would have matched exactly. A member of
    # two groups that each lend an address, editing one of them,
    # submits one edited address and one untouched: walked in a single
    # pass, whichever group came first would read the other's untouched
    # line as its own edit and the other would read a deletion. Every
    # untouched line is struck first, and only what is left is
    # attributed.
    #
    # Matching ignores `item` numbers, because the Apple clients
    # renumber them freely (docs/apple-contacts.md), and pairs each
    # address with its label line (#label_of's pairing): a line says
    # what a component says when its components and its label read the
    # same, so a relabel is an edit like any other and a label arriving
    # as an X-ABLabel or a TYPE is the same label. Every address still
    # unclaimed after both passes is one of the member's own, and the
    # caller replaces the member's own rows with them in submission
    # order — an address that cannot be attributed lands there too, so
    # an edit is never lost.
    #
    # Pass two decides only for a group whose marker the submission
    # carries current (#stale_groups for what that means): a group it
    # does not is refused, its rows stay lent, and the lines that would
    # have been attributed its edit land among the member's own.
    #
    # Both passes draw from #unaccounted_lines, so a member's own
    # address that came back as it was sent is never a candidate for a
    # lent one.
    #: (VCard vcard, Set[String] stale) -> [VCard, Array[AddressEdit]]
    def subtract_lent_addresses(vcard, stale)
      lent = (@before&.lent || []).flat_map { |row|
        row.addresses.map { |address| [row.group, address] } #: [Group, ContactDetails::LentAddress]
      }
      return [vcard, []] if lent.empty?

      pool = unaccounted_lines(vcard)
      taken = [] #: Array[VCard::Parser::Line]
      edits = [] #: Array[AddressEdit]

      moved = lent.reject { |_, row|
        candidates = pool.select { it.names?("ADR") && !it.property.nil? }
        match = candidates.find { |line| unedited_address?(line, pool, row.address) }
        taken.concat(strike_address(pool, match)) if match
        match
      }

      ambiguous = 0
      moved.each do |group, row|
        next if stale.include?(group.id)

        candidates = pool.select { it.names?("ADR") && !it.property.nil? }
        case candidates.length
        when 0
          edits << AddressEdit.new(group_id: group.id, position: row.position, address: nil)
        when 1
          line = candidates.fetch(0)
          property = line.property
          read = property.nil? ? nil : Contact.address_of(property, label_of(line, pool))
          # What the member edited is what the matching reads; the
          # parameters and companions stay the group's, a client
          # adding its own `pref` to a line it rewrote.
          address = read&.with(parameters: row.address.parameters, companions: row.address.companions)
          edits << AddressEdit.new(group_id: group.id, position: row.position, address:)
          taken.concat(strike_address(pool, line))
        else
          ambiguous += 1
        end
      end
      report_ambiguous_inherited_lines(ambiguous)
      [struck(vcard, taken), edits]
    end

    # The one NOTE the submission carries, read back into what the
    # member keeps and what each lending group is asked of — the
    # inverse of what Contact composes, over sections rather than
    # lines (docs/plans/2026-09-25-one-note-per-contact.md). The card
    # that comes back carries the member's own half as its NOTE line
    # or none at all, which #take_note reads into the note component;
    # the groups' halves leave as NoteEdits, their text and not a line.
    #
    # Where no group lends a note the NOTE lines are the member's own
    # and keep their bytes — joined into one and reported only where a
    # client sent several, the one-note invariant's answer to foreign
    # input (that plan, "The split" and "The invariant").
    #
    # The one reading that is not the section grammar's: a value with
    # no headers that is exactly a lent note's text is a client of the
    # two-line shape sending back what macOS truncated it to — the
    # last NOTE, which that shape put last (docs/apple-contacts.md,
    # "Only the last of two notes survives"). It reads as that note
    # present and every other one gone.
    #
    # A group the submission may not edit (#stale_groups) is refused
    # per section: an absent section of its is not believed a
    # deletion, and an edited one cannot be kept without writing
    # section grammar into the member's own note, which takes the
    # whole value to the mangle bargain below.
    #: (VCard vcard, Set[String] stale) -> [VCard, Array[NoteEdit]]
    def subtract_lent_notes(vcard, stale)
      rows = (@before&.lent || []).filter_map { |row| [row.group, row.note] if row.note }
      notes = vcard.lines.select { it.names?("NOTE") } #: Array[VCard::Parser::Line]
      return [members_own(vcard, notes), []] if rows.empty?

      labels = rows.map { it.fetch(0).label }
      if labels.uniq.length != labels.length
        report_indistinguishable_labels
        return [members_own(vcard, notes), []]
      end

      # No NOTE at all is every section deleted — the cleared field,
      # which takes the member's own text with it (the plan's "The
      # split") — each deletion believed only of a group whose
      # current lines the submission was composed from.
      deletions = rows.filter_map { |group, _|
        NoteEdit.new(group_id: group.id, text: nil) unless stale.include?(group.id)
      }
      return [vcard, deletions] if notes.empty?

      values = notes.map { it.property&.text }
      if values.any?(&:nil?)
        report_unreadable_sections
        return [members_own(vcard, notes), []]
      end
      value = values.join("\n\n")

      split = NoteSections.split(value, labels)
      if split.sections.empty?
        # The two-line shape's truncation (see the method comment).
        kept = rows.find { |_, text| text == value }
        unless kept.nil?
          return [
            vcard.replace("NOTE", []),
            rows.reject { it.equal?(kept) }.filter_map { |group, _|
              NoteEdit.new(group_id: group.id, text: nil) unless stale.include?(group.id)
            },
          ]
        end

        report_unreadable_sections
        return [members_own(vcard, notes), []]
      end

      if split.sections.length != split.sections.map(&:label).uniq.length
        report_unreadable_sections
        return [members_own(vcard, notes), []]
      end

      texts = split.sections.to_h {
        [it.label, it.text] #: [String, String]
      }
      # A refused group's edited section: the text cannot land on the
      # group and cannot be spliced into the member's own note, so the
      # whole value stays on the member — duplication rather than
      # loss, visible beside what the groups keep lending, the mangle
      # bargain (#report_unreadable_sections').
      refused_edit = rows.any? { |group, text|
        said = texts[group.label]
        stale.include?(group.id) && !said.nil? && said != text
      }
      return [members_own(vcard, notes), []] if refused_edit

      edits = rows.filter_map { |group, text|
        next if stale.include?(group.id)

        case texts[group.label]
        when nil
          NoteEdit.new(group_id: group.id, text: nil)
        when text
          nil
        else
          NoteEdit.new(group_id: group.id, text: texts[group.label])
        end
      }
      [vcard.replace("NOTE", member_note(split.member)), edits]
    end

    # The member's half of a split NOTE as the lines to store: the
    # escaped text, or none at all — empty text is no note, and
    # #take_note reads both alike. No terminator, so the line takes its
    # neighbour's and an LF card stays one.
    #: (String text) -> Array[String]
    def member_note(text)
      return [] if text.empty?

      ["NOTE:#{VCard.escape(text)}"]
    end

    # The submission's NOTE lines kept as the member's own: their
    # bytes where there is one, joined where foreign input sent
    # several — the one-note invariant's answer to a client
    # (docs/plans/2026-09-25-one-note-per-contact.md, "The invariant").
    #: (VCard vcard, Array[VCard::Parser::Line] notes) -> VCard
    def members_own(vcard, notes)
      return vcard if notes.length <= 1

      report_many_note_lines(notes.length)
      texts = notes.map { it.property&.text || it.verbatim.chomp }
      vcard.replace("NOTE", ["NOTE:#{VCard.escape(texts.join("\n\n"))}"])
    end

    # Whether a submitted ADR still says what the component says: its
    # components equal, and its label reads the same. A question about
    # what it says and not its bytes — macOS re-serializes every card
    # it touches (docs/apple-contacts.md, "The client rewrites every
    # card it touches") — with the types and the X-ABLabel folded into
    # the one label the way a reader shows them
    # (docs/plans/2026-10-25-contacts-on-entities.md, "Matching what
    # comes back"), spelled as an address holds one
    # (Address.canonical_label) so a word compares as itself. The
    # address's parameters and companions are not read: Contacts adds a
    # `pref` to every line it rewrites, which no member meant as an edit
    # of the group's address.
    #: (VCard::Parser::Line line, Array[VCard::Parser::Line] pool, ContactDetails::Address address) -> bool
    def unedited_address?(line, pool, address)
      property = line.property
      return false if property.nil?

      components = property.components
      components << "" while components.length < 7
      return false unless [
        address.po_box, address.extended, address.street, address.locality,
        address.region, address.postal_code, address.country,
      ] == components

      label = Contact.label_of(label_of(line, pool), property.types)
      Contact::Address.canonical_label(label) == address.label
    end

    # The submission's lines less one ADR, and its label, for each of
    # the member's own addresses that came back saying what it says:
    # what the groups lent plus whatever the client wrote beside it, the
    # pool a lent address is attributed from. One line per address, so
    # an entity that holds one of something and submits two leaves one
    # over. The lines set aside stay in the card, being the member's own.
    #: (VCard vcard) -> Array[VCard::Parser::Line]
    def unaccounted_lines(vcard)
      pool = vcard.lines.dup
      (@before&.addresses || []).each do |address|
        line = pool.find { it.names?("ADR") && unedited_address?(it, pool, address) }
        next if line.nil?

        label = label_of(line, pool)
        strike(pool, line)
        strike(pool, label) if label
      end
      pool
    end

    # A lent address's lines out of the pool — the ADR, its label, and
    # its companions (ContactDetails.companions_of) — so that none is
    # left in the member's card naming a line that left it.
    #: (Array[VCard::Parser::Line] pool, VCard::Parser::Line line) -> Array[VCard::Parser::Line]
    def strike_address(pool, line)
      label = label_of(line, pool)
      riding = ContactDetails.companions_of(line, pool)
      riding.unshift(label) if label
      [strike(pool, line), *riding.map { strike(pool, it) }]
    end

    # The line out of the pool, so no second lent line is attributed
    # it. `index` rather than `delete`, which would take every copy of
    # a line a card carries twice.
    #: (Array[VCard::Parser::Line] pool, VCard::Parser::Line line) -> VCard::Parser::Line
    def strike(pool, line)
      pool.delete_at(
        pool.index(line) #: Integer
      )
      line
    end

    # The card without the lines the matching struck, by identity
    # rather than through #extract and #insert, which would move a
    # member's own lines of the same name to the card's end, or
    # #substitute, which takes the first copy of identical bytes. The
    # lines this leaves keep their positions, so a submission that was
    # the served card round-trips to the bytes it was composed from
    # and the PUT can answer with a strong etag (RFC 6352 section
    # 6.3.2.3).
    #: (VCard vcard, Array[VCard::Parser::Line] taken) -> VCard
    def struck(vcard, taken)
      return vcard if taken.empty?

      VCard.new(vcard.lines.reject { |line| taken.any? { it.equal?(line) } }.map(&:verbatim).join)
    end

    # The `X-ABLabel` sharing a property group with `line`, the other
    # half of the pair #unedited_address? reads as one. Nil for an
    # ungrouped line, or a group the pool holds no label for.
    #: (VCard::Parser::Line line, Array[VCard::Parser::Line] pool) -> VCard::Parser::Line?
    def label_of(line, pool)
      group = line.property&.group
      return if group.nil?

      pool.find { |other|
        property = other.property
        !property.nil? && property.group&.casecmp?(group) == true && property.name.casecmp?("X-ABLABEL")
      }
    end

    # The ambiguity report: a lent address that came back as neither
    # what it says nor a single candidate is one this server cannot
    # attribute — two lines of that name arrived that the member's card
    # does not explain, and calling either the edit would be a guess.
    # The line stays the member's own and the group keeps what it
    # lends, the same bargain report_unrecognized_bday_line makes; the
    # member serves its own copy and the group's beside it until
    # someone reconciles them, which is why the news is worth having.
    #: (Integer count) -> void
    def report_ambiguous_inherited_lines(count)
      return if count.zero?

      Sentry.capture_message(
        "a submitted card left #{count} inherited address(es) with more than one line of that name to attribute them to",
        level: :warning,
      )
    end

    # A contact has one note (docs/plans/2026-09-25-one-note-per-
    # contact.md), so a submission with several is a client this server
    # did not compose for; they join, and the news is worth having
    # because whatever each carried is now one value on one member.
    #: (Integer count) -> void
    def report_many_note_lines(count)
      Sentry.capture_message("a submitted card carried #{count} NOTE lines", level: :warning)
    end

    # The mangle report: a NOTE this server cannot read back into
    # sections — a header a person's editing took apart, two sections
    # claiming one label, or a line that will not read. The whole value
    # stays on the member and the groups keep what they lend, so the
    # member serves its own copy and each group's section beside it
    # until someone reconciles them, which is why the news is worth
    # having (docs/plans/2026-09-25-one-note-per-contact.md, "The
    # split").
    #: () -> void
    def report_unreadable_sections
      Sentry.capture_message(
        "a submitted NOTE could not be read back into its sections; it stays on the member",
        level: :warning,
      )
    end

    # Two of a contact's groups lend under one label — a nameless
    # group's id and a group named the same — so a section read under
    # that label cannot say which lent it. Nothing is attributed and
    # nothing propagates, the same bargain #report_unreadable_sections
    # makes.
    #: () -> void
    def report_indistinguishable_labels
      Sentry.capture_message(
        "two of a contact's groups share a label, so its submitted NOTE cannot be attributed",
        level: :warning,
      )
    end
  end
end
