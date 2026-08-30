
require "digest"
require "pathname"
require "sequel"

require "pro_tacts/contact"
require "pro_tacts/vcard/parser"

Sequel.extension :migration

module ProTacts
  # The transactional store: one SQLite database holding each contact's
  # card exactly as it was submitted.
  #
  # Three kinds of state live here and they are not equally precious.
  # The cards are the truth about contact data, and the reason they are
  # stored as the card rather than a parse of it is
  # docs/plans/2026-08-24-vcard-storage-and-groups.md. The change log is
  # the truth about history, and is why this is one database rather than
  # a directory of files: "what changed since token X" cannot be
  # recovered from current state, so a card, its etag, and its
  # change-log entry have to land or fail together. Everything else is
  # an index derived from the cards, and #rebuild_index will make it
  # again from nothing.
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
      cards.order(:id).map { contact_from(it) }
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

    # `sole` rather than `first`: the id is the primary key, so a second
    # row is a corruption and not a choice to make quietly. It raises on
    # no row too, which here is the ordinary answer for an href nobody
    # has — the 404 path — so that one is caught and turned back into
    # nil.
    #: (String id) -> Contact?
    def contact(id)
      contact_from(cards.where(id:).sole)
    rescue Sequel::NoMatchingRow
      nil
    end

    # The id of the card whose UID property holds this value, if one
    # does — the read behind the no-uid-conflict precondition (RFC 6352
    # section 6.3.2.1). It reads the index, so a card that failed to
    # parse is invisible here; no card that arrived by PUT can be in
    # that state, because PUT rejects what will not parse before
    # storing it. `sole` for the same reason `contact` uses it: two
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
    # The strings are UTF-8 by contract, and the adapter holds the store
    # to it: the sqlite3 gem encodes every bound value to UTF-8, so a
    # binary-flagged byte above 7 bits raises at the bind, and bytes
    # that are not UTF-8 at all stop at the insert, which SQLite refuses
    # to store as text. Rack's binary is relabelled before this —
    # Web#utf8, where the wire meets the route.
    #: (String id, String vcard) -> Contact
    def put(id, vcard)
      contact = Contact.for(id:, vcard:)
      @database.transaction do
        cards
          .insert_conflict(target: :id, update: {vcard: Sequel[:excluded][:vcard], updated_at: NOW})
          .insert(id: contact.id, vcard: contact.vcard)
        record(contact.id, "put", contact.etag)
        reindex(contact)
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
    # projection ever disagrees with the cards, this is the repair.
    # Returns the ids of cards that did not parse, which are served in
    # full but contribute nothing to the index.
    #: () -> Array[String]
    def rebuild_index
      @database.transaction do
        card_properties.delete
        contacts.each.with_object([]) do |contact, unindexed|
          unindexed << contact.id unless reindex(contact)
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

    #: (String card_id, String action, String? etag) -> void
    def record(card_id, action, etag)
      change_log.insert(card_id:, action:, etag:)
    end

    # Replaces a card's rows in the index. Rebuilt wholesale rather than
    # diffed because it is derived data and replacing it is the cheaper
    # correct thing. Returns whether the card parsed: one that does not
    # is still served, so refusing to index it must not fail the write.
    #: (Contact contact) -> bool
    def reindex(contact)
      # Before the parse, so that a card which has stopped parsing does
      # not keep the rows from when it did.
      card_properties.where(card_id: contact.id).delete
      properties = properties_of(contact.vcard)
      return false if properties.nil?

      properties.each.with_index do |property, position|
        card_properties.insert(
          card_id: contact.id,
          position:,
          property_group: property.group,
          name: property.name,
          value: property.value,
        )
        property.parameters.each do |name, value|
          card_parameters.insert(card_id: contact.id, position:, name:, value:)
        end
      end
      true
    end

    # A card's properties, or nil when the bytes are not a vCard.
    #: (String vcard) -> Array[VCard::Property]?
    def properties_of(vcard)
      VCard::Parser.parse(vcard)
    rescue VCard::ParseError
      nil
    end

    # Applies whatever migrations the database has not seen. On one it is
    # already current with, this is a read of Sequel's schema_info table
    # and nothing else, which is cheap enough to do on every open and
    # leaves no way to serve from a database a deploy forgot to migrate.
    #: () -> void
    def migrate
      Sequel::Migrator.run(@database, MIGRATIONS.to_s)
    end

    # The etag comes back out of the card rather than out of a column, so
    # a row can never carry one that disagrees with the bytes beside it.
    #: (Hash[Symbol, untyped] row) -> Contact
    def contact_from(row)
      Contact.for(id: row.fetch(:id).to_s, vcard: row.fetch(:vcard).to_s)
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
