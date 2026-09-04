require "date"
require "digest"
require "pathname"
require "sequel"
require "sentry-ruby"

require "pro_tacts/birthday"
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
  # (docs/plans/2026-08-31-partial-birthdays.md). Everything else is
  # an index derived from the cards, and #rebuild_index will make it
  # again from nothing.
  #
  # Every Contact this store hands out is composed, never the stored
  # card alone: a birthday is subtracted out of a card on the way in
  # and composed back in on the way out, so the vcard and the etag a
  # caller sees — and the etag the change log records — describe the
  # card a client downloads, not the bytes on disk.
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

    # One entry in the change log. The signature is in
    # sig/pro_tacts/store.rbs with Store's own.
    # @rbs skip
    Change = Data.define(:sequence, :card_id, :action, :etag, :created_at)

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
      cards.order(:id).map { contact_from(it, birthdays[it.fetch(:id).to_s]) }
    end

    # Every contact paired with its card's updated_at, newest first — the
    # read behind any "recently updated" surface. Same shape and cost as
    # #contacts, ordered by the column SQLite already stamps rather than
    # by id.
    #: () -> Array[RecentContact]
    def contacts_by_recency
      birthdays = birthdays_by_id
      cards.order(Sequel.desc(:updated_at)).map {
        RecentContact.new(
          contact: contact_from(it, birthdays[it.fetch(:id).to_s]),
          updated_at: it.fetch(:updated_at).to_s,
        )
      }
    end

    # The collection's content tag: one value that changes when any card
    # is added, removed, or changed and never otherwise, so a client
    # comparing two of them learns whether to resync — never what
    # changed. Sorting the id-and-etag lines keeps it independent of the
    # order rows come back in while staying sensitive to membership and
    # content.
    #
    # It costs a read of every card, because an etag is derived from a
    # card's bytes rather than stored beside them. The changes table
    # already holds a monotonic sequence that answers the same question
    # for the price of one indexed read, and switching to it is part of
    # the incremental-sync work: it would change the value a client
    # holds, and it moves on every write rather than on every change,
    # which is a different promise than the one this makes.
    #: () -> String
    def ctag
      Digest::SHA256.hexdigest(contacts.map { "#{it.id} #{it.etag}" }.sort.join("\n"))
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
      birthdays
        .join(:cards, id: :card_id)
        .map { upcoming_from(it, today) }
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
      contact_from(cards.where(id:).sole, birthday_of(id))
    rescue Sequel::NoMatchingRow
      nil
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
    # The strings are UTF-8 by contract, and the adapter holds the store
    # to it: the sqlite3 gem encodes every bound value to UTF-8, so a
    # binary-flagged byte above 7 bits raises at the bind, and bytes
    # that are not UTF-8 at all stop at the insert, which SQLite refuses
    # to store as text. The body — the one binary input — is relabelled
    # and judged in the same breath where it is read, in write_card, so
    # nothing that is not text gets this far; VCard's own raise is the
    # assertion under that, and the bind is the third line.
    #: (String id, String vcard) -> Contact
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
      card = VCard.new(vcard)
      existing = birthday_of(id)
      birthday, stored =
        case card.extract("BDAY")
        in [[line], rest]
          report_unrecognized_bday_lines([line])
          property = bday_of(line)
          birthday = property && Birthday.from_property(property)
          [birthday, birthday ? rest : card]
        in [[], _]
          # The rewrite arm: carry the unrendered lines out of the
          # stored card, report the unrecognized ones' loss, and keep
          # whatever an unseen model row holds.
          carried, lost = carried_and_lost_bday_lines(stored_card(id))
          kept = existing && !existing.served? ? existing : nil
          report_lost_bday_lines(lost)
          [kept, card.insert(carried)]
        in [lines, _]
          # More than one BDAY: cardinality-broken data, kept verbatim
          # and reported like any other unrecognized line.
          report_unrecognized_bday_lines(lines)
          [nil, card]
        end

      # The Contact this returns is the composed one, and the logged
      # etag is its hash, so a client's token describes the card it
      # downloads.
      contact = Contact.for(id:, vcard: with_birthday(stored, birthday))
      @database.transaction do
        cards
          .insert_conflict(target: :id, update: {vcard: Sequel[:excluded][:vcard], updated_at: NOW})
          .insert(id: contact.id, vcard: stored.to_s)
        write_birthday(contact.id, birthday)
        record(contact.id, "put", contact.etag)
        reindex(contact.id, stored)
      end
      contact
    end

    # Removes a card, leaving the tombstone that tells a syncing client
    # it is gone. Returns whether there was anything to remove.
    #: (String id) -> bool
    def delete(id)
      @database.transaction do
        deleted = cards.where(id:).delete.positive?
        record(id, "delete", nil) if deleted
        deleted
      end
    end

    # The change log from a sequence number on, oldest first. Nothing
    # reads it yet — incremental sync is the task that will — but the
    # entries have to be written from the very first card, because a gap
    # in them is a change some client is never told about.
    #: (?after: Integer) -> Array[Change]
    def changes(after: 0)
      change_log.where(Sequel[:sequence] > after).order(:sequence).map { change_from(it) }
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
        cards.order(:id).all.each { reindex(it.fetch(:id).to_s, VCard.new(it.fetch(:vcard).to_s)) }
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

    #: (String card_id, String action, String? etag) -> void
    def record(card_id, action, etag)
      change_log.insert(card_id:, action:, etag:)
    end

    # Replaces a card's rows in the index. Rebuilt wholesale rather than
    # diffed because it is derived data and replacing it is the cheaper
    # correct thing. Indexes the lines that read and says nothing about
    # the ones that did not: the card is served from its bytes either
    # way, and there is no version of this write that fixes a line the
    # parser cannot read. Takes the stored card — with the birthday
    # already subtracted — so the index never sees a BDAY no stored
    # card carries.
    #: (String id, VCard card) -> void
    def reindex(id, card)
      # Before the parse, so that a card which has stopped parsing does
      # not keep the rows from when it did.
      card_properties.where(card_id: id).delete

      card.properties.each.with_index do |property, position|
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
    #: (VCard? card) -> [Array[String], Array[VCard::Parser::Line]]
    def carried_and_lost_bday_lines(card)
      return [[], []] if card.nil?

      bdays, = card.extract("BDAY")
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

    # The etag comes back out of the card rather than out of a column, so
    # a row can never carry one that disagrees with the bytes beside it.
    # The card is composed with its birthday first, so both halves
    # describe what a client downloads.
    #: (Hash[Symbol, untyped] row, Birthday? birthday) -> Contact
    def contact_from(row, birthday)
      Contact.for(
        id: row.fetch(:id).to_s,
        vcard: with_birthday(VCard.new(row.fetch(:vcard).to_s), birthday),
      )
    end

    # The card to serve: the stored card with its birthday composed
    # back in, immediately before END:VCARD. A birthday with no wire
    # form, or none at all, leaves the card exactly as it is.
    #: (VCard card, Birthday? birthday) -> VCard
    def with_birthday(card, birthday)
      line = birthday && birthday.to_line
      return card if line.nil?

      card.insert([line])
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
    #: (Hash[Symbol, untyped] row, Date today) -> UpcomingBirthday?
    def upcoming_from(row, today)
      birthday = birthday_from(row)
      month, day = birthday.month, birthday.day
      return if month.nil? || day.nil?

      candidate = date_in(today.year, month, day)
      UpcomingBirthday.new(
        contact: contact_from(row, birthday),
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
        created_at: row.fetch(:created_at).to_s,
      )
    end
  end
end
