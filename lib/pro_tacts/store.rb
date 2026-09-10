require "date"
require "pathname"
require "securerandom"
require "sequel"
require "sentry-ruby"

require "pro_tacts/birthday"
require "pro_tacts/card_diff"
require "pro_tacts/contact"
require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

Sequel.extension :migration

module ProTacts
  # The transactional store: one SQLite database holding each contact's
  # card exactly as it was submitted.
  #
  # Four kinds of state live here and they are not equally precious.
  # The cards are the truth about contact data, and the reason they are
  # stored as the card rather than a parse of it is
  # docs/plans/2026-08-24-vcard-storage-and-groups.md. The change log is
  # the truth about history, and is why this is one database rather than
  # a directory of files: "what changed since token X" cannot be
  # recovered from current state, so a card, its etag, and its
  # change-log entry have to land or fail together. The birthdays are
  # the third thing that cannot be rebuilt — a partial date has no
  # vCard 3.0 spelling, so it lives beside its card rather than in it
  # (docs/plans/2026-08-31-partial-birthdays.md). The groups are the
  # fourth — membership and the lines a group contributes to its
  # members' served cards, facts no stored card carries and so nothing
  # can re-derive. Everything else is an index derived from the cards,
  # and #rebuild_index will make it again from nothing.
  #
  # Every Contact this store hands out is composed, never the stored
  # card alone: a birthday and the lines a contact inherits from its
  # groups are both subtracted out of a card on the way in, and Contact
  # composes them back in on read — so the vcard and the etag a caller
  # sees, and the etag the change log records, describe the card a
  # client downloads, not the bytes on disk.
  #
  # Sequel's transactions join one already open rather than failing on
  # SQLite's lack of nesting, which is what lets the group fan-out this
  # design needs — one member's card rewriting its group and every other
  # member's card — call #put from inside a larger write and still be a
  # single atomic unit.
  #
  # The signature lives in sig/pro_tacts/store.rbs, for the Change Data
  # class the inline syntax cannot read.
  class Store
    # @rbs @database: Sequel::Database

    # One entry in the change log: what happened to a card, what it
    # hashed to afterwards, and which of its lines the write moved. The
    # signature is in sig/pro_tacts/store.rbs with Store's own.
    # @rbs skip
    Change = Data.define(:sequence, :card_id, :action, :etag, :diff, :created_at)

    # A contact paired with when its card last changed. Contact itself
    # carries no timestamp — it is derived from the card alone, see its
    # own comment — so a surface that sorts or displays recency (the
    # admin UI's "recently updated" list) gets it from here instead.
    # @rbs skip
    RecentContact = Data.define(:contact, :updated_at)

    # A contact paired with the calendar day its birthday next lands
    # on — the read behind the admin's upcoming-birthdays list, where
    # the order is the coming year's, not the stored components'.
    # @rbs skip
    UpcomingBirthday = Data.define(:contact, :occurs_on)

    # SQLite has no ON UPDATE, so the column default stamps a row on
    # insert and this stamps it again on the way past. Same expression as
    # the migration's, deliberately: the database keeps the clock, so two
    # rows written in one transaction agree.
    NOW = Sequel.lit("strftime('%Y-%m-%dT%H:%M:%fZ', 'now')") #: untyped

    # Every write is short, so a writer that finds the database locked is
    # better off waiting than raising: two requests saving at once is
    # ordinary, and SQLITE_BUSY straight back to the client is not.
    BUSY_TIMEOUT = 5_000 #: Integer

    # Hex in the letters jj renders a change id with: 0 is z, f is k,
    # and every digit lands in k-z, so an id is never a hash and never
    # a word its author meant. `tr` maps the alphabets in one pass, in
    # the order this pair is written.
    REVERSE_HEX = "zyxwvutsrqponmlk" #: String

    # How many ids a create draws before giving up. Four letters is one
    # of 65,536 and an address book holds groups by the dozen, so a
    # first collision is already unlucky and a run of eight is a broken
    # generator rather than a run of bad draws — better to say so than
    # to spin.
    GROUP_ID_ATTEMPTS = 8 #: Integer

    # The property names whose value is structured rather than free
    # text (RFC 2426 section 3.2.1), among the two a group may lend:
    # ADR is components, NOTE is text (db/migrations/004_groups.rb).
    # Which reading applies is the caller's to know — the parser holds
    # no value types — and this is the one caller that compares values.
    STRUCTURED_VALUES = %w[ADR].freeze #: Array[String]

    # Sequel's migrations, run on open. They ship with the code rather
    # than with a deployment, so the path is relative to this file.
    # `__dir__` is nil only for code with no file behind it, which a
    # required library is not, and the assertion says so to Steep.
    MIGRATIONS = Pathname.new(
      __dir__ #: String
    ).parent.parent / "db" / "migrations" #: Pathname

    # The store a process keeps: config.ru builds one of these and hands
    # it to the app, and Sequel pools the connections behind it. Not
    # named `open`, which every object already has from Kernel.
    #: (Pathname | String path) -> Store
    def self.at(path)
      new(Sequel.sqlite(path.to_s, timeout: BUSY_TIMEOUT))
    end

    # The same, closed again when the block returns, for a database that
    # is not the one this process serves from: a fixture, a test, a rake
    # task pointed somewhere else.
    #: [T] (Pathname | String path) { (Store) -> T } -> T
    def self.connect(path)
      store = at(path)
      begin
        yield store
      ensure
        store.close
      end
    end

    #: (Sequel::Database database) -> void
    def initialize(database)
      @database = database
      # WAL so a poll can read while a save writes. Foreign keys need no
      # pragma: Sequel turns them on for every SQLite connection it
      # opens, which is what makes the index's cascades fire.
      @database.run("PRAGMA journal_mode = WAL")
      # lib/sequel/extensions/sole.rb, for the reads that mean one row.
      @database.extension(:sole)
      migrate
    end

    #: () -> void
    def close
      @database.disconnect
    end

    # Every contact, ordered by id so that a listing does not depend on
    # what SQLite feels like returning.
    #: () -> Array[Contact]
    def contacts
      birthdays = birthdays_by_id
      inherited = inherited_by_id
      cards.order(:id).map {
        id = it.fetch(:id).to_s
        contact_from(it, birthdays[id], inherited.fetch(id, []))
      }
    end

    # Every contact paired with its card's updated_at, newest first — the
    # read behind any "recently updated" surface. Same shape and cost as
    # #contacts, ordered by the column SQLite already stamps rather than
    # by id.
    #: () -> Array[RecentContact]
    def contacts_by_recency
      birthdays = birthdays_by_id
      inherited = inherited_by_id
      cards.order(Sequel.desc(:updated_at)).map {
        id = it.fetch(:id).to_s
        RecentContact.new(
          contact: contact_from(it, birthdays[id], inherited.fetch(id, [])),
          updated_at: it.fetch(:updated_at).to_s,
        )
      }
    end

    # The collection's content tag: one value that changes when any card
    # is added, removed, or changed and never otherwise, so a client
    # comparing two of them learns whether to resync — never what
    # changed. The change log's sequence is that value, for the one
    # indexed read it costs. It moves on a rewrite that stores identical
    # bytes too, where the hash this replaced did not: the promise
    # trades a spurious resync — every etag unchanged, nothing fetched —
    # for never missing a change.
    #: () -> String
    def ctag
      latest_sequence.to_s
    end

    # The change log's current sequence: the collection's version, and
    # the number a sync token carries (RFC 6578 section 3). Zero when
    # nothing has ever been written. Ordered and taken rather than
    # Dataset#max, which steep reads as Enumerable#max — an Integer
    # argument, not a column.
    #: () -> Integer
    def latest_sequence
      change_log.order(Sequel.desc(:sequence)).first&.fetch(:sequence).to_i
    end

    # Birthdays that land on a coming calendar day, in arrival order:
    # today's first, and one already passed this year wrapped onto next
    # year rather than dropped — the wrap that keeps "upcoming" a
    # year-round answer instead of a January one. Only the shapes with
    # both a month and a day land anywhere: a year alone, a year and
    # month, and a month alone sit on no calendar day, and a day with
    # no month arrives in no week in particular, so none of the four is
    # this list's to place. A birthday is database state rather than a
    # line in a card (docs/plans/2026-08-31-partial-birthdays.md), so
    # this reads the table rather than scanning cards for BDAY.
    #: (Integer limit, ?today: Date) -> Array[UpcomingBirthday]
    def upcoming_birthdays(limit, today: Date.today)
      inherited = inherited_by_id
      birthdays
        .join(:cards, id: :card_id)
        .map { upcoming_from(it, today, inherited.fetch(it.fetch(:card_id).to_s, [])) }
        .compact
        .sort_by { [it.occurs_on, it.contact.id] }
        .first(limit)
    end

    # `sole` rather than `first`: the id is the primary key, so a second
    # row is a corruption and not a choice to make quietly. It raises on
    # no row too, which here is the ordinary answer for an href nobody
    # has — the 404 path — so that one is caught and turned back into
    # nil.
    #: (String id) -> Contact?
    def contact(id)
      contact_from(cards.where(id:).sole, birthday_of(id), inherited_of(id))
    rescue Sequel::NoMatchingRow
      nil
    end

    # The groups a contact belongs to, by the label each is shown
    # under, ordered by group id — a rename must not move a tag, the
    # same reason #inherited_rows orders by it. Membership is the whole
    # answer here, so a group that lends nothing appears too, where the
    # inherited reads have nothing of it to carry. Off the contact
    # rather than on it: what a group lends is in the card and belongs
    # to the model of one, and which groups a contact is in is a
    # relationship the card never carries.
    #: (String id) -> Array[String]
    def groups_of(id)
      group_members
        .join(:groups, id: Sequel[:group_members][:group_id])
        .where(card_id: id)
        .order(Sequel[:groups][:id])
        .select(group_label.as(:label))
        .map { it.fetch(:label).to_s }
    end

    # The id of the card whose UID property holds this value, if one
    # does — the read behind the no-uid-conflict precondition (RFC 6352
    # section 6.3.2.1). It reads the index, so a card whose UID line
    # would not read is invisible here; no card that arrived by PUT can
    # be in that state, because PUT reads the UID off the same lines
    # before storing it. `sole` for the same reason `contact` uses it: two
    # cards sharing a UID is a corruption to raise on, not a choice.
    #: (String uid) -> String?
    def card_id_with_uid(uid)
      card_properties.where(name: "UID", value: uid).sole.fetch(:card_id).to_s
    rescue Sequel::NoMatchingRow
      nil
    end

    # Stores a card and everything that has to move with it: the
    # change-log entry a client's sync token counts on, carrying the etag
    # this card hashed to now, and the index rows read off the card. One
    # transaction, because the log entry cannot be rebuilt from anything.
    #
    # What is stored is the card minus its birthday, which moves into
    # the birthdays table — vCard 3.0 cannot carry a partial date, so
    # no stored card carries the model's BDAY and every read composes
    # it back in (docs/plans/2026-08-31-partial-birthdays.md).
    #
    # A card rather than its bytes, so the reading a caller already
    # made is the one the split below decides from: a PUT has asked
    # whether the bytes are a card at all and whose UID they carry
    # before it gets here (Web#write_card), and taking the card it
    # asked those of leaves the walk behind them made once.
    #
    # The strings are UTF-8 by contract, and the adapter holds the store
    # to it: the sqlite3 gem encodes every bound value to UTF-8, so a
    # binary-flagged byte above 7 bits raises at the bind, and bytes
    # that are not UTF-8 at all stop at the insert, which SQLite refuses
    # to store as text. The body — the one binary input — is relabelled
    # and judged in the same breath where it is read, in write_card, so
    # nothing that is not text gets this far; VCard's own raise, at the
    # construction the caller makes, is the assertion under that, and
    # the bind is the third line.
    #: (String id, VCard vcard) -> Contact
    def put(id, vcard)
      # The birthday half of the split a write makes, one arm per shape
      # a submitted card's BDAY lines can take. One line that reads as
      # a modeled birthday moves out of the card and into the model;
      # any other BDAY — the vCard 4.0 forms, a foreign sentinel, a
      # line that will not parse, a BDAY sharing its line's bytes with
      # another, more than one — is data the model
      # cannot recompose and stays in the card byte for byte, with the
      # model emptied so nothing composes a second BDAY beside it
      # (RFC 6352 section 6.3.2.2). No BDAY at all is a client's
      # rewrite, and macOS Contacts drops the BDAY lines it cannot
      # render from every card it writes (docs/macos-contacts.md):
      # what the stored card held in a spelling no client renders
      # rides across the rewrite, what it held that a client could
      # see was the user's deletion, an unseen model row survives as
      # nothing a client ever saw, and what nobody recognizes is
      # reported rather than lost in silence.
      existing = birthday_of(id)
      # The card as it stands before this write, read once for the two
      # halves that need it: the rewrite arm below, which carries
      # unrendered BDAY lines across, and the subtraction after the
      # case, which accounts for the member's own lines before
      # attributing any to a group.
      own = stored_card(id)
      birthday, stored =
        case vcard.extract("BDAY")
        in [[line], rest]
          report_unrecognized_bday_lines([line])
          property = bday_of(line)
          birthday = property && Birthday.from_property(property)
          [birthday, birthday ? rest : vcard]
        in [[], _]
          # The rewrite arm: carry the unrendered lines out of the
          # stored card, report the unrecognized ones' loss, and keep
          # whatever an unseen model row holds.
          carried, lost = carried_and_lost_bday_lines(own)
          kept = existing && !existing.served? ? existing : nil
          report_lost_bday_lines(lost)
          [kept, vcard.insert(carried)]
        in [lines, _]
          # More than one BDAY: cardinality-broken data, kept verbatim
          # and reported like any other unrecognized line.
          report_unrecognized_bday_lines(lines)
          [nil, vcard]
        end

      # The other half of the split, the same shape as the birthday's:
      # what the groups lend comes back out of the submission before it
      # is stored, so a rewrite cannot materialize a group's lines into
      # the member's own card.
      #
      # The Contact this returns is the composed one — those lines put
      # back, read off membership as it stands at this write — and the
      # logged etag is its hash, so a client's token describes the card
      # it downloads.
      inherited = inherited_of(id)
      # The card this write replaces, composed from the parts already
      # read here rather than through #contact, which would read all
      # three again. Membership cannot move during a put, so the
      # inheritance either side of it is the one read above.
      before = own && Contact.new(id:, stored: own, birthday: existing, inherited:)
      stored = subtract_inherited(stored, inherited, own)
      contact = Contact.new(id:, stored:, birthday:, inherited:)
      @database.transaction do
        cards
          .insert_conflict(target: :id, update: {vcard: Sequel[:excluded][:vcard], updated_at: NOW})
          .insert(id: contact.id, vcard: stored.to_s)
        write_birthday(contact.id, birthday)
        record(contact.id, "put", contact.etag, CardDiff.between(before&.vcard, contact.vcard))
        reindex(contact.id, stored)
      end
      contact
    end

    # The store's own editor changed a contact, against #put's "a
    # client submitted a card" — why the two paths cannot be one is
    # docs/plans/2026-09-05-web-card-editor.md, "Two write paths
    # through the store". The card input is the stored one by
    # definition, and `birthday:` is the model's whole new state, an
    # upsert or a delete, never a splice
    # (docs/plans/2026-09-07-web-birthday-editor.md). A card rather
    # than its bytes, for #put's reason: the editor spliced one to
    # make this save, and re-reading its bytes here would walk them
    # again to reach what the caller already had.
    #: (String id, VCard vcard, birthday: Birthday?) -> Contact
    def rewrite(id, vcard, birthday:)
      before = contact(id)
      contact = Contact.new(id:, stored: vcard, birthday:, inherited: inherited_of(id))
      @database.transaction do
        cards
          .insert_conflict(target: :id, update: {vcard: Sequel[:excluded][:vcard], updated_at: NOW})
          .insert(id: contact.id, vcard: vcard.to_s)
        write_birthday(contact.id, birthday)
        record(contact.id, "edit", contact.etag, CardDiff.between(before&.vcard, contact.vcard))
        reindex(contact.id, vcard)
      end
      contact
    end

    # Removes a card, leaving the change-log entry that tells a syncing
    # client it is gone. The tombstone carries the whole card away in
    # its diff — every line removed and none added — which is the only
    # record left of what was here, the row itself being gone.
    #: (String id) -> bool
    def delete(id)
      @database.transaction do
        before = contact(id)
        deleted = cards.where(id:).delete.positive?
        record(id, "delete", nil, CardDiff.between(before&.vcard, nil)) if deleted
        deleted
      end
    end

    # Creates a group and hands back the id it was given. The name is
    # the author's label and optional; a group without one is displayed
    # by its id (see #inherited_rows), and the empty string is refused
    # by the schema rather than kept as a second spelling of nameless.
    #
    # The id is minted here rather than taken from the caller, for the
    # shape db/migrations/005_group_identity.rb pins. The insert is
    # what settles a collision, not a read before it: two creates
    # drawing at once would both find the same id free, so a duplicate
    # comes back as the primary key's own violation and the next
    # attempt draws again.
    #: (?name: String?) -> String
    def create_group(name: nil)
      GROUP_ID_ATTEMPTS.times do
        id = next_group_id
        begin
          groups.insert(id:, name:)
          return id
        rescue Sequel::UniqueConstraintViolation
          next
        end
      end
      raise "no free group id in #{GROUP_ID_ATTEMPTS} draws: #{groups.count} groups already"
    end

    # The change log from a sequence number on, oldest first: the window
    # a sync-collection report answers from (RFC 6578 section 3.2) — the
    # entries after the client's token are the changes it has not seen.
    # The entries have to be written from the very first card, because a
    # gap in them is a change some client is never told about.
    #: (?after: Integer) -> Array[Change]
    def changes(after: 0)
      change_log.where(Sequel[:sequence] > after).order(:sequence).map { change_from(it) }
    end

    # One card's entries, newest first — the history the admin's contact
    # page renders. The order is against #changes' deliberately: that
    # read is a sync window and hands back the order a client applies,
    # this one is a record someone reads, where the last thing that
    # happened is what they came for. A card id and not a foreign key
    # (see db/migrations/001_create_contacts_schema.rb), so an id whose
    # card is gone still answers with the history that ends in its
    # tombstone.
    #: (String id) -> Array[Change]
    def changes_of(id)
      change_log.where(card_id: id).order(Sequel.desc(:sequence)).map { change_from(it) }
    end

    # Drops the index and derives it again from the stored cards alone.
    # Always safe to run: nothing is authoritative here, so if the
    # projection ever disagrees with the cards, this is the repair. Raw
    # rows rather than #contacts, which compose birthdays in: the index
    # reflects what is stored, and no stored card carries a BDAY.
    #: () -> void
    def rebuild_index
      @database.transaction do
        card_properties.delete
        cards.order(:id).all.each do
          reindex(it.fetch(:id).to_s, VCard.new(it.fetch(:vcard).to_s))
        end
      end
    end

    private

    #: () -> Sequel::Dataset
    def cards
      @database[:cards]
    end

    #: () -> Sequel::Dataset
    def change_log
      @database[:changes]
    end

    #: () -> Sequel::Dataset
    def card_properties
      @database[:card_properties]
    end

    #: () -> Sequel::Dataset
    def card_parameters
      @database[:card_parameters]
    end

    #: () -> Sequel::Dataset
    def birthdays
      @database[:birthdays]
    end

    #: () -> Sequel::Dataset
    def groups
      @database[:groups]
    end

    #: () -> Sequel::Dataset
    def group_members
      @database[:group_members]
    end

    # Four hex digits spelled in REVERSE_HEX. SecureRandom rather than
    # rand: the draws have to be independent of anything a caller can
    # observe or seed, and two bytes of it is exactly the four digits
    # the id is wide.
    #: () -> String
    def next_group_id
      SecureRandom.hex(2).tr("0-9a-f", REVERSE_HEX)
    end

    # The diff comes in already computed rather than being taken here
    # off a `before` and an `after`: only the caller knows which two
    # cards its write was between, and a delete's `after` is nothing at
    # all.
    #: (String card_id, String action, String? etag, CardDiff diff) -> void
    def record(card_id, action, etag, diff)
      change_log.insert(card_id:, action:, etag:, diff: diff.to_json)
    end

    # Replaces a card's rows in the index. Rebuilt wholesale rather than
    # diffed because it is derived data and replacing it is the cheaper
    # correct thing. Indexes the lines that read and says nothing about
    # the ones that did not: the card is served from its bytes either
    # way, and there is no version of this write that fixes a line the
    # parser cannot read. Takes the stored card — with the birthday
    # already subtracted — so the index never sees a BDAY no stored
    # card carries.
    #: (String id, VCard vcard) -> void
    def reindex(id, vcard)
      # Before the parse, so that a card which has stopped parsing does
      # not keep the rows from when it did.
      card_properties.where(card_id: id).delete

      vcard.properties.each.with_index do |property, position|
        card_properties.insert(
          card_id: id,
          position:,
          property_group: property.group,
          name: property.name,
          value: property.value,
        )
        property.parameters.each do |name, value|
          card_parameters.insert(card_id: id, position:, name:, value:)
        end
      end
    end

    # Applies whatever migrations the database has not seen. On one it is
    # already current with, this is a read of Sequel's schema_info table
    # and nothing else, which is cheap enough to do on every open and
    # leaves no way to serve from a database a deploy forgot to migrate.
    #: () -> void
    def migrate
      Sequel::Migrator.run(@database, MIGRATIONS.to_s)
    end

    # The card currently stored for an id, or nil for a card being
    # created. A plain `first` read: the primary key leaves `sole`
    # nothing to catch, and no row is the ordinary answer.
    #: (String id) -> VCard?
    def stored_card(id)
      row = cards.where(id:).first
      row && VCard.new(row.fetch(:vcard).to_s)
    end

    # The BDAY a decision may be made of: the line's property, when it
    # has one and it names BDAY. Found by name rather than position,
    # and safe to act on because the line is the unit a rewrite or a
    # move to the model carries and a line holds at most one property
    # (VCard::Parser::Line) — so moving its bytes moves this and
    # nothing else. Nil for any other shape, the empty line a failed
    # read leaves included.
    #: (VCard::Parser::Line line) -> VCard::Parser::Property?
    def bday_of(line)
      property = line.property
      property if property&.name&.casecmp?("BDAY")
    end

    # A stored card's BDAY lines in two piles: the verbatim lines a
    # rewrite carries across — values no client renders — and the ones
    # it drops unwitnessed, which no client renders and no whitelist
    # recognizes. Lines a client rendered are in neither pile: their
    # absence is a deletion the rewrite already honors.
    #: (VCard? vcard) -> [Array[String], Array[VCard::Parser::Line]]
    def carried_and_lost_bday_lines(vcard)
      return [[], []] if vcard.nil?

      bdays, = vcard.extract("BDAY")
      carried, rest = bdays.partition { |line|
        property = bday_of(line)
        property && Birthday.unrendered_value?(property.value)
      }
      lost = rest.reject { |line|
        property = bday_of(line)
        property && Birthday.rendered?(property)
      }
      [carried.map(&:verbatim), lost]
    end

    # The arrival report: a BDAY line this server can neither model,
    # recognize as rendered, nor recognize as carried is unexpected
    # input, and storing it verbatim would be the last anyone heard of
    # it. The message carries no card content
    # (ProTacts::SentryScrubber's line); the values stay on the
    # machine, where the admin view shows them raw.
    #: (Array[VCard::Parser::Line] lines) -> void
    def report_unrecognized_bday_lines(lines)
      unrecognized = lines.count { |line|
        # A line with no property is one this server could not read at
        # all, and a value it never read is not a value it failed to
        # recognize. The line's bytes are stored either way.
        next false if line.property.nil?

        property = bday_of(line)
        property.nil? || (!Birthday.rendered?(property) && !Birthday.unrendered_value?(property.value))
      }
      return if unrecognized.zero?

      Sentry.capture_message(
        "a submitted card carried #{unrecognized} BDAY line(s) no client renders and no whitelist recognizes",
        level: :warning,
      )
    end

    # The submitted card with the lines its groups lend it taken back
    # out: served is stored plus inherited, so stored is submitted
    # minus inherited and a client that PUTs back what it downloaded
    # stores what it started with
    # (docs/plans/2026-08-24-vcard-storage-and-groups.md, "Groups
    # compose into cards"). Without this a member's rewrite would
    # materialize the group's lines into its own card, and a later edit
    # to the group would reach nobody.
    #
    # Each lent line is classified against the submission, and only one
    # of the four shapes moves a byte. The line coming back saying what
    # the group lends is the group's, untouched, and it goes. One line
    # of that name left over is an edit to the shared line and none is
    # a deletion of it: both stay in the card as they arrived, because
    # propagating either is the next task's (the plan's "Edits
    # propagate to the group"), and storing the edit is what keeps it
    # from being lost meanwhile. More than one left over is a line this
    # cannot attribute at all, and reports rather than guesses.
    #
    # #substitute rather than #extract and #insert, which would move a
    # member's own lines of the same name to the card's end: the lines
    # this leaves keep their positions, so a submission that was the
    # served card round-trips to the bytes it was composed from and the
    # PUT can answer with a strong etag (RFC 6352 section 6.3.2.3).
    #: (VCard vcard, Array[Contact::Inherited] inherited, VCard? own) -> VCard
    def subtract_inherited(vcard, inherited, own)
      return vcard if inherited.empty?

      unaccounted = unaccounted_lines(vcard, own)
      untouched = [] #: Array[VCard::Parser::Line]
      ambiguous = 0

      inherited.each do |lent|
        lent_line = parsed_line(lent.line)
        candidates = unaccounted.select { it.names?(property_name(lent.line)) }
        # Blind to lines saying the same thing the way the editor's
        # digests are blind to identical bytes
        # (VCard::Parser::Line#digest): where a member's own card
        # carries what its group lends, which copy this takes is
        # undecidable and their saying the same thing makes it not
        # matter.
        match = candidates.find { unedited?(it, lent_line) }
        if match
          unaccounted.delete_at(
            unaccounted.index(match) #: Integer
          )
          untouched << match
        elsif candidates.length > 1
          ambiguous += 1
        end
      end

      report_ambiguous_inherited_lines(ambiguous)
      untouched.reduce(vcard) { |rest, line| rest.substitute(line.digest, []) }
    end

    # A lent line as the parser reads it: one logical line, the group
    # schema admitting no other shape (db/migrations/004_groups.rb).
    #: (String line) -> VCard::Parser::Line
    def parsed_line(line)
      VCard.new(line).lines.fetch(0)
    end

    # Whether a submitted line still says what the group lends, which
    # is a question about what it says and not about its bytes: macOS
    # re-serializes every card it touches, so `ADR;TYPE=home` comes
    # back `ADR;type=HOME;type=pref` on an address nobody edited
    # (docs/macos-contacts.md, "The client rewrites every card it
    # touches"). Comparing bytes reads every such line as an edit.
    #
    # What a line says is its value and its types: a member who
    # relabels a lent address from home to work edited the shared line
    # as surely as one who changed a digit of it, and an edit is the
    # group's to take (the plan's "Edits propagate to the group"). So a
    # type that moved is not subtracted, and stays in the member's card
    # where the propagation will find it.
    #
    # Every other parameter goes uncompared, being the half the client
    # rewrites without being asked: it drops the ones it does not model
    # — a `NOTE;LANGUAGE=en` comes back bare — and fills in defaults on
    # the ones it does.
    #
    # A line that will not read has no value to compare and falls back
    # to its bytes, which still recognize the line nobody touched.
    #: (VCard::Parser::Line line, VCard::Parser::Line lent) -> bool
    def unedited?(line, lent)
      value = value_of(lent)
      return line.verbatim.chomp == lent.verbatim.chomp if value.nil?

      value_of(line) == value && kept_types?(line, lent)
    end

    # Whether a submitted line carries the types the group lent it,
    # across the two rewrites they survive: the values come back
    # uppercased and `pref` filled in, so neither side's case counts
    # and neither counts `pref` (types_of drops it). An untyped line
    # comes back untyped, so no types compares to no types and a
    # member who labels one has edited it (docs/macos-contacts.md, "An
    # address type the client cannot model becomes a custom label").
    #
    # One shape this reads as an edit that nobody made: a type
    # Contacts has no field for comes back as an `X-ABLabel` on a
    # property group, taking the `TYPE` parameter with it, on an
    # address nobody touched. A group lending `ADR;TYPE=dom` therefore
    # materializes into every member's card at their next sync — see
    # the task "Read a custom label as the type it was made from".
    #: (VCard::Parser::Line line, VCard::Parser::Line lent) -> bool
    def kept_types?(line, lent)
      types_of(line) == types_of(lent)
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

    # A line's TYPE values, as the set the round trip preserves:
    # casefolded, `pref` dropped as the client's own addition, and
    # sorted because `TYPE=home;TYPE=pref` and `TYPE=pref,home` are one
    # thing (RFC 2426 section 3.2.1, which the parser reads into pairs
    # either way). Empty for a line that would not read, which has no
    # parameters to compare.
    #: (VCard::Parser::Line line) -> Array[String]
    def types_of(line)
      property = line.property
      return [] if property.nil?

      property.parameters
        .filter_map { |name, value| value.downcase if name.casecmp?("TYPE") }
        .reject { it == "pref" }
        .uniq
        .sort
    end

    # The submission's lines that the member's own stored card does not
    # already explain — one struck per stored line of the same bytes,
    # so a card that stores one of something and submits two leaves one
    # over. What is left is what the groups lent plus whatever the
    # client wrote beside it, which is the pool a lent line is
    # attributed from. Everything for a card being created, which has
    # no stored lines to explain anything.
    #: (VCard vcard, VCard? own) -> Array[VCard::Parser::Line]
    def unaccounted_lines(vcard, own)
      stored = own ? own.lines.map { it.verbatim.chomp } : [] #: Array[String]
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
    # bargain report_unrecognized_bday_lines makes, and carries no card
    # content for the same reason (ProTacts::SentryScrubber).
    #: (Integer count) -> void
    def report_ambiguous_inherited_lines(count)
      return if count.zero?

      Sentry.capture_message(
        "a submitted card left #{count} inherited line(s) with more than one line of that name to attribute them to",
        level: :warning,
      )
    end

    # The loss report, the rewrite's half of the arrival one: a stored
    # BDAY no client renders and no whitelist recognizes is about to be
    # dropped, and nobody would know.
    #: (Array[VCard::Parser::Line] lines) -> void
    def report_lost_bday_lines(lines)
      return if lines.empty?

      Sentry.capture_message(
        "a rewrite dropped #{lines.length} BDAY line(s) no client renders and no whitelist carries",
        level: :warning,
      )
    end

    # The birthday travels beside the card rather than inside it, and
    # Contact composes the served one — its vcard, its etag, everything
    # a caller reads — with the inherited lines beside it, so all
    # describe what a client downloads rather than the bytes on disk.
    #: (Hash[Symbol, untyped] row, Birthday? birthday, Array[Contact::Inherited] inherited) -> Contact
    def contact_from(row, birthday, inherited)
      Contact.new(
        id: row.fetch(:id).to_s,
        stored: VCard.new(row.fetch(:vcard).to_s),
        birthday:,
        inherited:,
      )
    end

    # The model's half of a write: hold the birthday the card gave up,
    # or empty the model — a BDAY that stayed in the card must not grow
    # a composed twin beside it, and a deletion must take the row with
    # it.
    #: (String id, Birthday? birthday) -> void
    def write_birthday(id, birthday)
      if birthday
        birthdays
          .insert_conflict(
            target: :card_id,
            update: {year: Sequel[:excluded][:year], month: Sequel[:excluded][:month], day: Sequel[:excluded][:day]},
          )
          .insert(card_id: id, year: birthday.year, month: birthday.month, day: birthday.day)
      else
        birthdays.where(card_id: id).delete
      end
    end

    # Every birthday, keyed by card, for the listing reads that compose
    # a whole collection in one pass.
    #: () -> Hash[String, Birthday]
    def birthdays_by_id
      birthdays.all.to_h {
        [it.fetch(:card_id).to_s, birthday_from(it)] #: [String, Birthday]
      }
    end

    # One card's birthday, or nil for none. A plain `first` read rather
    # than `sole`: card_id is the primary key, so there is no ambiguity
    # for `sole` to catch and no row is the ordinary answer.
    #: (String id) -> Birthday?
    def birthday_of(id)
      row = birthdays.where(card_id: id).first
      row && birthday_from(row)
    end

    # The content lines a contact inherits, each beside the name of the
    # group lending it — every property of every group it belongs to,
    # nothing of a group that holds nothing, and [] for a contact in no
    # group at all. Ordered by group id and then position, so the
    # composed card is the same bytes every read.
    #: (String id) -> Array[Contact::Inherited]
    def inherited_of(id)
      inherited_rows.where(card_id: id).map { inherited_from(it) }
    end

    # Every contact's inheritance in one pass, keyed by card, for the
    # listing reads that compose a whole collection — the same shape as
    # birthdays_by_id, for the same reason. Only a contact with
    # something to inherit appears; the absent key reads as [] at the
    # caller, which is what it means.
    #: () -> Hash[String, Array[Contact::Inherited]]
    def inherited_by_id
      inherited_rows.all
        .group_by { it.fetch(:card_id).to_s }
        .transform_values { |rows| rows.map { inherited_from(it) } }
    end

    # What to call a group on a screen: its name, or its id where it
    # has none (db/migrations/005_group_identity.rb). In SQL rather
    # than in Ruby so that both reads of it — a tag and an inherited
    # row's mark — are the one answer.
    #: () -> untyped
    def group_label
      Sequel.function(:coalesce, Sequel[:groups][:name], Sequel[:groups][:id])
    end

    # The join both inherited reads walk: a membership to the property
    # it inherits and to the group's own row for its name, qualified
    # and ordered so the composition neither depends on what SQLite
    # feels like returning nor trips over the group_id the tables
    # share. Ordered by the group's id rather than its name, because a
    # rename must not move a member's lines and change every etag in
    # the group.
    #
    # A group with no name is lent under its id instead, coalesced here
    # rather than at the surfaces: a mark on an inherited row names the
    # group it came from, and a group with no name still has to be
    # named as some one group among several
    # (db/migrations/005_group_identity.rb).
    #: () -> Sequel::Dataset
    def inherited_rows
      group_members
        .join(:group_properties, group_id: :group_id)
        .join(:groups, id: Sequel[:group_members][:group_id])
        .select(
          Sequel[:group_members][:card_id],
          group_label.as(:group_name),
          Sequel[:group_properties][:line],
        )
        .order(
          Sequel[:group_members][:card_id],
          Sequel[:group_properties][:group_id],
          Sequel[:group_properties][:position],
        )
    end

    #: (Hash[Symbol, untyped] row) -> Contact::Inherited
    def inherited_from(row)
      Contact::Inherited.new(group: row.fetch(:group_name).to_s, line: row.fetch(:line).to_s)
    end

    # A birthday row read as the model. The shape was validated on the
    # way in, so a row that no longer parses is corruption to raise on
    # rather than quietly drop.
    #: (Hash[Symbol, untyped] row) -> Birthday
    def birthday_from(row)
      Birthday.new(year: row[:year], month: row[:month], day: row[:day])
    end

    # One joined birthday-and-card row as an UpcomingBirthday, or nil
    # for a shape that lands on no calendar day (see
    # #upcoming_birthdays).
    #: (Hash[Symbol, untyped] row, Date today, Array[Contact::Inherited] inherited) -> UpcomingBirthday?
    def upcoming_from(row, today, inherited)
      birthday = birthday_from(row)
      month, day = birthday.month, birthday.day
      return if month.nil? || day.nil?

      candidate = date_in(today.year, month, day)
      UpcomingBirthday.new(
        contact: contact_from(row, birthday, inherited),
        occurs_on: candidate < today ? date_in(today.year + 1, month, day) : candidate,
      )
    end

    # A birthday's month and day as a date in `year`. A day the month
    # does not have — February 30, April 31 — was stored well-shaped but
    # calendar-nonsense (see Birthday), and lands on the month's last
    # day for ordering; what the view shows is the stored value.
    #: (Integer year, Integer month, Integer day) -> Date
    def date_in(year, month, day)
      Date.new(year, month, day)
    rescue ArgumentError
      Date.new(year, month, -1)
    end

    #: (Hash[Symbol, untyped] row) -> Change
    def change_from(row)
      Change.new(
        sequence: row.fetch(:sequence).to_i,
        card_id: row.fetch(:card_id).to_s,
        action: row.fetch(:action).to_s,
        etag: row.fetch(:etag),
        diff: CardDiff.from_json(row.fetch(:diff).to_s),
        created_at: row.fetch(:created_at).to_s,
      )
    end
  end
end
