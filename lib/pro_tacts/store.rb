require "date"
require "json"
require "pathname"
require "sequel"

require "pro_tacts/birthday"
require "pro_tacts/card_diff"
require "pro_tacts/change_id"
require "pro_tacts/contact"
require "pro_tacts/edited_contact"
require "pro_tacts/group"
require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

Sequel.extension :migration

module ProTacts
  # The transactional store: one SQLite database holding each contact's
  # card exactly as it was submitted.
  #
  # Six kinds of state live here and they are not equally precious.
  # Only the cards, the change log, the birthdays, the groups, the
  # books, and the group change log cannot be rebuilt, and each is
  # argued where it was decided: the first two in
  # docs/plans/2026-08-25-sqlite-schema.md,
  # "What the tables are for", the birthdays in
  # docs/plans/2026-08-31-partial-birthdays.md, the groups in
  # docs/plans/2026-08-24-vcard-storage-and-groups.md, the books in
  # docs/plans/2026-09-19-books-in-the-dump.md, the group change log
  # in docs/plans/2026-09-23-group-change-log.md. Everything else
  # is an index derived from the cards, and #rebuild_index will make
  # it again from nothing.
  #
  # Every Contact this store hands out is composed, never the stored
  # card alone: a birthday and the lines a contact inherits from its
  # groups are both subtracted out of a card on the way in
  # (EditedContact), and Contact composes them back in on read — so
  # the vcard and the etag a caller sees, and the etag the change log
  # records, describe the card a client downloads, not the bytes on
  # disk.
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

    # What an entry says happened. The four the schema admits and no
    # fifth — the CHECK constraint's own list
    # (db/migrations/006_change_diffs.rb), which is what refuses one
    # this does not name.
    module Action
      PUT = "put" #: String
      EDIT = "edit" #: String
      DELETE = "delete" #: String
      GROUP = "group" #: String
    end

    # One entry in the group change log: what happened to a group and
    # at which moment, with a detail shaped by the action — the name a
    # create or rename left, the lines a `lines` write moved in
    # CardDiff's spelling, the card a join or leave moved, and a
    # delete's tombstone carrying the whole group. The signature is in
    # sig/pro_tacts/store.rbs with Store's own.
    # @rbs skip
    GroupChange = Data.define(:sequence, :group_id, :action, :detail, :created_at)

    # What an entry says happened to a group. The six the schema
    # admits and no seventh — the CHECK constraint's own list
    # (db/migrations/011_group_change_log.rb), Action's own rule.
    module GroupAction
      CREATE = "create" #: String
      RENAME = "rename" #: String
      LINES = "lines" #: String
      JOIN = "join" #: String
      LEAVE = "leave" #: String
      DELETE = "delete" #: String
    end

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

    # stored cards by id, the birthdays by card id, the groups, and the
    # books — the name each named one goes by, keyed by login. What
    # `rake db:dump` writes (tasks/db.rake).
    # @rbs skip
    Snapshot = Data.define(:cards, :birthdays, :groups, :books)

    # A group as a picker names it: enough to show it and to submit it,
    # and no more. A Group carries the lines it lends and the ids of
    # its members, two reads beyond the group row itself (#load_groups);
    # a picker is a list of names to tick and needs neither, so
    # #group_choices reads only the row and a count of who is in it,
    # which the import's picker sorts by (Admin::ImportGroups). The
    # label is the same SQL one (#group_label), so a choice and a tag
    # never disagree about what to call a nameless group. Signed in
    # sig/pro_tacts/store.rbs, being a Data class.
    # @rbs skip
    GroupChoice = Data.define(:id, :name, :label, :member_count)

    # SQLite has no ON UPDATE, so the column default stamps a row on
    # insert and this stamps it again on the way past. Same expression as
    # the migration's, deliberately: the database keeps the clock, so two
    # rows written in one transaction agree.
    NOW = Sequel.lit("strftime('%Y-%m-%dT%H:%M:%fZ', 'now')") #: untyped

    # Every write is short, so a writer that finds the database locked is
    # better off waiting than raising: two requests saving at once is
    # ordinary, and SQLITE_BUSY straight back to the client is not.
    BUSY_TIMEOUT = 5_000 #: Integer

    # How many ids a create draws before giving up. The four letters
    # #create_group asks ChangeId for are one of 65,536, and an address
    # book holds groups by the dozen, so a first collision is already
    # unlucky and a run of eight is a broken generator rather than a run
    # of bad draws — better to say so than to spin.
    GROUP_ID_ATTEMPTS = 8 #: Integer

    # How many ids a re-id draws before giving up. Twelve letters are
    # one of 2^48, so GROUP_ID_ATTEMPTS' reasoning arrives intact at a
    # wider alphabet: a first collision is a broken generator rather
    # than a run of bad draws.
    CONTACT_ID_ATTEMPTS = 8 #: Integer

    # A book named `*`, which would be everyone's (#name_book).
    class EveryonesBookName < ArgumentError; end

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
      # BEGIN IMMEDIATE for every transaction, so the writes that read
      # before they write serialize instead of one of them dying on
      # SQLITE_BUSY however long BUSY_TIMEOUT is
      # (docs/plans/2026-09-09-group-edits-propagate.md, "Two edits,
      # one shared value"). Readers are unaffected: WAL is on above.
      @database.transaction_mode = :immediate
      # lib/sequel/extensions/sole.rb, for the reads that mean one row.
      @database.extension(:sole)
      migrate
    end

    #: () -> void
    def close
      @database.disconnect
    end

    # The store's state for a dump, in one read transaction so the parts
    # agree. Deferred rather than the store's usual immediate: a read
    # needs no write lock, and taking one would hold up writers.
    #: () -> Snapshot
    def snapshot
      @database.transaction(mode: :deferred) do
        Snapshot.new(
          cards: cards.order(:id).all.to_h {
            [it.fetch(:id).to_s, it.fetch(:vcard).to_s] #: [String, String]
          },
          birthdays: birthdays_by_id,
          groups: all_groups,
          books: all_books,
        )
      end
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
    # year-round answer instead of a January one. Where each lands, and
    # which shapes land nowhere, is Birthday#next_on's to say. A
    # birthday is database state rather than a line in a card
    # (docs/plans/2026-08-31-partial-birthdays.md), so this reads the
    # table rather than scanning cards for BDAY.
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
      contact!(id)
    rescue Sequel::NoMatchingRow
      nil
    end

    # The groups a contact belongs to, whole — a tag names one and
    # opens it — ordered by group id: a rename must not move a tag, the
    # same reason #inherited_rows orders by it. Membership is the whole
    # answer here, so a group that lends nothing appears too, where the
    # inherited reads have nothing of it to carry. Off the contact
    # rather than on it: what a group lends is in the card and belongs
    # to the model of one, and which groups a contact is in is a
    # relationship the card never carries.
    #: (String id) -> Array[Group]
    def groups_of(id)
      load_groups(
        labeled_groups
          .join(:group_members, group_id: :id)
          .where(card_id: id)
          .order(Sequel[:groups][:id])
          .all,
      )
    end

    # The cards one user's client syncs: every member of `sync:*` and of
    # `sync:<name>`, each once (docs/plans/2026-09-12-per-user-books.md),
    # where the name is the login's book name or the login itself
    # (docs/plans/2026-09-16-book-names.md). Matched as spelled: a login
    # whose case reads badly gets a name rather than a folded match.
    # Named for the cards rather than for the book, because `books` is
    # the table of the books that have names
    # (docs/plans/2026-09-21-books-not-book-names.md).
    #: (String login) -> Set[String]
    def book_cards(login)
      ids = groups.where(name: [Group::EVERYONE, own_sync_name(login)]).select_map(:id)
      Set.new(group_members.where(group_id: ids).select_map(:card_id).map(&:to_s))
    end

    # The name a login's book goes by. A login with no row has a book
    # all the same and it goes by the login, so that is the answer
    # rather than a nil for every caller to spell the fallback out
    # again (docs/plans/2026-09-21-books-not-book-names.md). Whether a
    # book was named is a question nothing asks; #name_book is how one
    # is set either way.
    #: (String login) -> String
    def book_name(login)
      books.where(login:).sole.fetch(:name).to_s
    rescue Sequel::NoMatchingRow
      login
    end

    # Sets the name a login's book goes by, or with nil or a blank goes
    # back to the login. The login's `sync:` group, if it has one, is
    # renamed in the same transaction, so the book keeps its cards and
    # #rename_group logs every member for the clients syncing it. A name
    # another login's book goes by raises on the unique index, and `*`
    # is refused before the transaction, #put's reason for building a
    # Contact outside one.
    #: (String login, String? name) -> void
    def name_book(login, name)
      name = name.to_s.strip
      name = nil if name.empty?
      raise EveryonesBookName, "#{Group::EVERYONE} is everyone's book, not #{login}'s" if name == "*"

      @database.transaction do
        group = groups.where(name: own_sync_name(login)).select_map(:id).first
        books.where(login:).delete
        books.insert(login:, name:) unless name.nil?
        rename_group(group.to_s, name: own_sync_name(login)) unless group.nil?
      end
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
    # What is stored is the card minus its birthday and minus what its
    # groups lend it, both composed back in on read; EditedContact
    # takes the submission apart and this writes the parts.
    #
    # A card rather than its bytes, so the reading a caller already
    # made is the one EditedContact decides from: a PUT has asked
    # whether the bytes are a card at all and whose UID they carry
    # before it gets here (Web#write_card).
    #
    # The strings are UTF-8 by contract and the bind is the third line
    # holding them to it, under Web#write_card's relabel-and-judge and
    # VCard's own raise. AGENTS.md, "Those tables are STRICT", has the
    # whole of it.
    #
    # `client` marks a client's write: a card it creates joins `sync:*`,
    # created on first use
    # (docs/plans/2026-09-15-client-creates-join-everyone.md). A
    # put over a card that exists joins nothing.
    #: (String id, VCard vcard, ?client: bool) -> Contact
    def put(id, vcard, client: false)
      # The contact this write replaces, read once for the two that want
      # it: the edit, which reads the submission against it, and the
      # change log's diff.
      before = contact(id)
      stored, birthday, edits = EditedContact.new(vcard, before:).decomposed

      # The Contact this returns is the composed one — the lent lines
      # put back, read off membership as it stands at this write — and
      # the logged etag is its hash, so a client's token describes the
      # card it downloads. Membership cannot move during a put, so the
      # inheritance either side of it is the one read above.
      inherited = before&.inherited || [] #: Array[Contact::Inherited]
      # Built before the transaction as well as inside it, because its
      # constructor is where an id that could not be served is refused
      # and a refusal from inside a transaction reaches the caller
      # wearing Sequel's own error class. Composition is lazy, so the
      # one the fan-out throws away below cost nothing to make.
      contact = Contact.new(id:, stored:, birthday:, inherited:)
      @database.transaction do
        # The groups move first, so that everything composed below is
        # the card this write leaves behind: the etag the change log
        # records is what a client downloading this member now gets,
        # group line included. The fan-out brackets the edits with a
        # read of every other member either side of them.
        unless edits.empty?
          fan_out(member_ids(edits.map(&:group_id).uniq), except: id) { apply_group_edits(edits) }
          contact = Contact.new(id:, stored:, birthday:, inherited: inherited_of(id))
        end
        upsert_card(contact.id, stored)
        # After the card, which the membership names by foreign key, and
        # before the log entry, which records the card composed with
        # whatever the group lends. The put's entry is the card's arrival
        # in the book, so the join writes none of its own.
        if client && before.nil?
          group_members.insert(group_id: everyone_group_id, card_id: contact.id)
          contact = Contact.new(id:, stored:, birthday:, inherited: inherited_of(contact.id))
        end
        write_birthday(contact.id, birthday)
        record(
          contact.id,
          action: Action::PUT,
          etag: contact.etag,
          diff: CardDiff.between(before&.vcard, contact.vcard),
        )
        reindex(contact.id, stored)
        contact
      end
    end

    # Why this and #put cannot be one path is
    # docs/plans/2026-09-05-web-card-editor.md, "Two write paths
    # through the store". The card input is the stored one by
    # definition, and `birthday:` is the model's whole new state, an
    # upsert or a delete, never a splice
    # (docs/plans/2026-09-07-web-birthday-editor.md). A card rather
    # than its bytes, for #put's reason: the editor spliced one to
    # make this save, and re-reading its bytes here would walk them
    # again to reach what the caller already had.
    #: (String id, VCard vcard, birthday: Birthday?) -> Contact
    def save_edit(id, vcard, birthday:)
      before = contact(id)
      contact = Contact.new(id:, stored: vcard, birthday:, inherited: inherited_of(id))
      @database.transaction do
        upsert_card(contact.id, vcard)
        write_birthday(contact.id, birthday)
        record(
          contact.id,
          action: Action::EDIT,
          etag: contact.etag,
          diff: CardDiff.between(before&.vcard, contact.vcard),
        )
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
        record(id, action: Action::DELETE, etag: nil, diff: CardDiff.between(before&.vcard, nil)) if deleted
        deleted
      end
    end

    # Gives a contact the id this server would have minted for it, and
    # hands the new id back. Every row that names the card moves with
    # it — the birthday, the memberships, the index, and the change
    # log's history, because the contact is the same contact and its
    # page keeps its record. The stored card's UID is rewritten to
    # match: a PUT must carry the id as its UID (Web#write_card), so a
    # card still spelling the old id could never be written again. A
    # card with no UID, or several, comes out with the one line — the
    # shape every write through #put already leaves.
    #
    # What a syncing client hears is written new rather than moved:
    # the old href's delete beside the new one's put, one transaction,
    # because a token silently skips whatever the log missed (see
    # #put). Without the pair, a client holding an older token would
    # keep serving the dead href out of its cache forever.
    #: (String id) -> String
    def reid(id)
      # #contact! rather than #contact's nil-for-404: no row here is the
      # caller's mistake to hear about as Sequel::NoMatchingRow, not a
      # request to answer.
      before = contact!(id)

      CONTACT_ID_ATTEMPTS.times do
        new_id = ChangeId.mint(ChangeId::CONTACT_LENGTH)
        # A card with no UID line gains one here, and several collapse
        # to it: #insert lands it before END:VCARD, the envelope's own
        # last word, where every card this server writes leaves it.
        _, rest = before.stored.extract("UID")
        stored = rest.insert(["UID:#{new_id}\r\n"])
        begin
          @database.transaction do
            # Deferred rather than ordered: every child row names the id
            # the cards row is leaving, so no sequence of plain updates
            # satisfies a foreign key that checks per row — the children
            # cannot move before the parent does, and the parent cannot
            # move while the children remain. `defer_foreign_keys` is
            # the one FK pragma that works inside a transaction (it
            # resets at commit); `foreign_keys` itself is a no-op there
            # (db/migrations/005_group_identity.rb records the reason).
            @database.run("PRAGMA defer_foreign_keys = ON")
            cards.where(id:).update(id: new_id, vcard: stored.to_s, updated_at: NOW)
            birthdays.where(card_id: id).update(card_id: new_id)
            group_members.where(card_id: id).update(card_id: new_id)
            change_log.where(card_id: id).update(card_id: new_id)
            # The index is a projection, dropped and re-derived below
            # rather than moved — the deal #reindex always gives it. The
            # parameters follow their properties away on the cascade.
            card_properties.where(card_id: id).delete
            after = contact!(new_id)
            record(id, action: Action::DELETE, etag: nil, diff: CardDiff.between(before.vcard, nil))
            record(
              new_id,
              action: Action::PUT,
              etag: after.etag,
              diff: CardDiff.between(before.vcard, after.vcard),
            )
            reindex(new_id, stored)
          end
          return new_id
        rescue Sequel::UniqueConstraintViolation
          # The minted id collided with a card already holding it; the
          # only unique constraint this write can hit.
          next
        end
      end
      raise "no free contact id in #{CONTACT_ID_ATTEMPTS} draws"
    end

    # Creates a group and hands back the id it was given. The name is
    # the author's label and optional; a group without one is displayed
    # by its id (see #inherited_rows), and the empty string is refused
    # by the schema rather than kept as a second spelling of nameless.
    # Logged in the group's own log as every group write is, the
    # create's detail carrying the name it was created under.
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
        id = ChangeId.mint(4)
        begin
          @database.transaction do
            groups.insert(id:, name:)
            record_group_change(id, action: GroupAction::CREATE, detail: {"name" => name})
          end
          return id
        rescue Sequel::UniqueConstraintViolation
          # The id collided, or the name did
          # (db/migrations/008_group_names.rb). Drawing again only helps
          # the first; the second is the caller's to hear.
          raise if groups.where(id:).empty?

          next
        end
      end
      raise "no free group id in #{GROUP_ID_ATTEMPTS} draws: #{groups.count} groups already"
    end

    # Every group, ordered by id — the order #groups_of and the
    # composition both use, so a rename never moves one.
    #: () -> Array[Group]
    def all_groups
      load_groups(labeled_groups.order(:id).all)
    end

    # Every group as a picker needs it: the row, its label and how many
    # are in it, without the lines it lends or the members it holds.
    # #all_groups' one read where a picker would otherwise pay for two,
    # the members read among them being the one that grows with the
    # book — `sync:*` holds every contact, so listing groups to tick
    # would read the whole address book to show none of it
    # (Admin::GroupDialog, Admin::ImportGroups). The count is a
    # subquery SQLite answers from group_members' primary key, which
    # leads with group_id, so no card is read to make it. Ordered by
    # id like #all_groups; a picker sorts by what it shows.
    #: () -> Array[GroupChoice]
    def group_choices
      member_count = group_members.where(group_id: Sequel[:groups][:id]).select(Sequel.function(:count).*)
      labeled_groups.select_append(member_count.as(:member_count)).order(:id).all.map { |row|
        GroupChoice.new(id: row.fetch(:id).to_s, name: row.fetch(:name)&.to_s, label: row.fetch(:label).to_s,
                        member_count: row.fetch(:member_count).to_i)
      }
    end

    # One group, or nil for an id nobody has: the admin's 404 path,
    # #contact's own shape.
    #: (String id) -> Group?
    def group(id)
      load_groups([labeled_groups.where(id:).sole]).fetch(0)
    rescue Sequel::NoMatchingRow
      nil
    end

    # A group's name, or none — NULL being the one spelling of
    # nameless (db/migrations/005_group_identity.rb), so a blank is
    # stored as that rather than refused by the schema. A name is on no
    # card, so no member's bytes move, but a `sync:` name is what puts a
    # card in a book: a rename into, out of, or between them moves every
    # member between books and logs each one (#fan_out's `moved`).
    # Logged in the group's own log only where the name moved, the log
    # recording what happened rather than that a save was asked
    # (docs/plans/2026-09-23-group-change-log.md, "One entry per
    # primitive").
    #: (String id, name: String?) -> void
    def rename_group(id, name:)
      name = nil if name.to_s.strip.empty?
      @database.transaction do
        was = groups.where(id:).sole.fetch(:name)&.to_s
        if was != name && (Group.sync_name?(was) || Group.sync_name?(name))
          members = member_ids([id])
          fan_out(members, moved: members) { groups.where(id:).update(name:) }
        else
          groups.where(id:).update(name:)
        end
        record_group_change(id, action: GroupAction::RENAME, detail: {"was" => was, "name" => name}) if was != name
      end
    end

    # Replaces what a group lends, wholesale, at positions from zero.
    # Every member serves the new lines from here on, so every member
    # whose served card moved is logged (#fan_out), and the group's own
    # log carries the lines the write moved in CardDiff's spelling. A
    # pure reorder is an entry with an empty diff — the multiset
    # difference cannot see it, but the lending order moved every
    # member's composed card, so it is a real write. A rewrite that
    # stores the same lines in the same order writes no entry, this
    # log's own bargain against the cards' (the plan's "One entry per
    # primitive"). A line outside what a group may hold is refused by
    # the CHECK, which is a caller's bug — the editor only builds ADR
    # and NOTE lines — and raises.
    #: (String id, Array[String] lines) -> void
    def set_group_lines(id, lines)
      @database.transaction do
        was = group_properties.where(group_id: id).order(:position).select_map(:line)
        diff = CardDiff.between_lines(was, lines)
        fan_out(member_ids([id])) do
          group_properties.where(group_id: id).delete
          lines.each.with_index do |line, position|
            group_properties.insert(group_id: id, position:, line:)
          end
        end
        if was != lines
          record_group_change(
            id,
            action: GroupAction::LINES,
            detail: {"added" => diff.added, "removed" => diff.removed},
          )
        end
      end
    end

    # The editor's whole save, as one transaction: a failure part-way
    # leaves the group as it was rather than half renamed. Leavers go
    # first and joiners last, so no card is logged for lines it was
    # about to stop or had yet to start serving.
    #: (String id, name: String?, lines: Array[String], members: Array[String]) -> void
    def edit_group(id, name:, lines:, members:)
      @database.transaction do
        current = member_ids([id])
        (current - members).each { remove_member(id, it) }
        rename_group(id, name:)
        set_group_lines(id, lines)
        (members - current).each { add_member(id, it) }
      end
    end

    # The members screen's save, #regroup's shape over a group: what
    # it toggled rather than the set it shows, one transaction so a
    # failure part-way leaves the membership as it was. Leavers first
    # and joiners last, #edit_group's reason.
    #: (String id, join: Array[String], leave: Array[String]) -> void
    def edit_members(id, join:, leave:)
      @database.transaction do
        leave.each { remove_member(id, it) }
        join.each { add_member(id, it) }
      end
    end

    # A card joins a group, and starts serving what the group lends.
    # Joining twice is joining once, and only the join that moved
    # membership is logged in the group's own log. Joining a `sync:`
    # group puts the card in a book, which the cards' own log carries
    # whether or not its bytes moved.
    #: (String group_id, String card_id) -> void
    def add_member(group_id, card_id)
      @database.transaction do
        joining = !member?(group_id, card_id)
        fan_out([card_id], moved: joining && sync_group?(group_id) ? [card_id] : []) {
          group_members.insert_conflict.insert(group_id:, card_id:)
        }
        record_group_change(group_id, action: GroupAction::JOIN, detail: {"card" => card_id}) if joining
      end
    end

    # A card leaves a group, and stops serving what the group lends —
    # the one lever the model has for "everyone but this member"
    # (docs/plans/2026-08-24-vcard-storage-and-groups.md, "Edits
    # propagate to the group"). Leaving a `sync:` group takes the card
    # out of a book, logged the way joining one is, and only the leave
    # that moved membership reaches the group's own log — leaving a
    # group never joined is nothing, not news.
    #: (String group_id, String card_id) -> void
    def remove_member(group_id, card_id)
      @database.transaction do
        leaving = member?(group_id, card_id)
        fan_out([card_id], moved: leaving && sync_group?(group_id) ? [card_id] : []) {
          group_members.where(group_id:, card_id:).delete
        }
        record_group_change(group_id, action: GroupAction::LEAVE, detail: {"card" => card_id}) if leaving
      end
    end

    # A group goes, and its members stop serving what it lent them: the
    # row's delete cascades the memberships and the lent lines away
    # with it (db/migrations/004_groups.rb). Members are logged as
    # leavers are (#remove_member's reason) — a `sync:` group's
    # whatever their bytes did, a book's deletion taking its cards out
    # of it. The group's own log closes with a tombstone carrying the
    # whole group, the card tombstone's bargain: the entry is the only
    # record left of what was here, the rows being gone. Everyone's
    # book is refused, #name_book's reason: every card a client created
    # joined it, so deleting it would tell every client to drop every
    # card it ever synced. A group nobody has is the ordinary miss,
    # #delete's shape.
    #: (String id) -> bool
    def delete_group(id)
      # A plain `first` read, #birthday_of's reason: id is the primary
      # key, so there is no ambiguity for `sole` to catch. Read here
      # rather than rescued around the whole method, which would have
      # swallowed a NoMatchingRow raised from inside the transaction
      # below and answered it as an ordinary miss.
      row = groups.where(id:).first
      return false if row.nil?

      name = row.fetch(:name).to_s
      # Refused before the transaction, #name_book's reason for the
      # same refusal: Sequel wraps what a rollback raises.
      raise EveryonesBookName, "#{Group::EVERYONE} is everyone's book, not a group to delete" if name == Group::EVERYONE

      @database.transaction do
        members = member_ids([id])
        lines = group_properties.where(group_id: id).order(:position).select_map(:line)
        record_group_change(
          id,
          action: GroupAction::DELETE,
          detail: {"name" => row.fetch(:name), "lines" => lines, "members" => members},
        )
        fan_out(members, moved: Group.sync_name?(name) ? members : []) {
          groups.where(id:).delete
        }
        true
      end
    end

    # A card's side of #edit_group: one transaction, leavers first and
    # joiners last for that method's reason. A named create makes its
    # group to join inside the same transaction, so a taken name
    # (#create_group) moves nothing.
    #: (String card_id, join: Array[String], leave: Array[String], ?create: Array[String]) -> void
    def regroup(card_id, join:, leave:, create: [])
      @database.transaction do
        join += create.map { create_group(name: it) }
        leave.each { remove_member(it, card_id) }
        join.each { add_member(it, card_id) }
      end
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

    # One group's entries, newest first — the history the group's page
    # renders, #changes_of's own order for its own reason: a record
    # someone reads, where the last thing that happened is what they
    # came for. A group id and not a foreign key (see the migration),
    # so an id whose group is gone still answers with the history that
    # ends in its tombstone.
    #: (String id) -> Array[GroupChange]
    def group_changes_of(id)
      group_changes.where(group_id: id).order(Sequel.desc(:sequence)).map { group_change_from(it) }
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

    #: () -> Sequel::Dataset
    def books
      @database[:books]
    end

    #: () -> Sequel::Dataset
    def group_properties
      @database[:group_properties]
    end

    #: () -> Sequel::Dataset
    def group_changes
      @database[:group_changes]
    end

    # A card written where one may already stand. The stamp is set
    # again on the way past because SQLite has no ON UPDATE and the
    # column default only fires on insert (NOW).
    #: (String id, VCard vcard) -> void
    def upsert_card(id, vcard)
      cards
        .insert_conflict(target: :id, update: {vcard: Sequel[:excluded][:vcard], updated_at: NOW})
        .insert(id:, vcard: vcard.to_s)
    end

    # The diff comes in already computed rather than being taken here
    # off a `before` and an `after`: only the caller knows which two
    # cards its write was between, and a delete's `after` is nothing at
    # all.
    #: (String card_id, action: String, etag: String?, diff: CardDiff) -> void
    def record(card_id, action:, etag:, diff:)
      change_log.insert(card_id:, action:, etag:, diff: diff.to_json)
    end

    # The group log's half of #record. The detail arrives already
    # built, action-shaped, for #record's own reason: only the writer
    # knows what its write moved.
    #: (String group_id, action: String, detail: Hash[String, untyped]) -> void
    def record_group_change(group_id, action:, detail:)
      group_changes.insert(group_id:, action:, detail: detail.to_json)
    end

    # The block's group writes, bracketed by a read of every member
    # they could move: what each served before and what each serves
    # after, and a `group` entry wherever the two differ. Why an entry
    # only where the bytes moved, why `except` is the writing member,
    # and why this runs inside the caller's own transaction are
    # docs/plans/2026-09-09-group-edits-propagate.md, "The fan-out".
    #
    # `moved` is the exception the plan does not cover: cards logged
    # whatever their bytes did, because a `sync:` membership moves a
    # card between books without touching what it serves
    # (docs/plans/2026-09-12-per-user-books.md, "The change log").
    #
    # Card ids rather than groups, because the cards a write can move
    # are not always members yet: a card joining a group is read before
    # the row that makes it one exists.
    #: (Array[String] cards, ?except: String?, ?moved: Array[String]) { () -> void } -> void
    def fan_out(cards, except: nil, moved: [])
      ids = cards - [except].compact
      before = ids.to_h {
        [it, contact!(it)] #: [String, Contact]
      }
      yield
      ids.each do |id|
        was = before.fetch(id)
        now = contact!(id)
        next if was.vcard.to_s == now.vcard.to_s && !moved.include?(id)

        record(id, action: Action::GROUP, etag: now.etag, diff: CardDiff.between(was.vcard, now.vcard))
      end
    end

    # The group's rows as the classification asked for them: a line
    # rewritten in place, or the row removed where a member deleted
    # what it lent. A removal leaves a gap in the positions, which
    # costs nothing — position orders a group's lines and is not
    # counted.
    #: (Array[EditedContact::GroupEdit] edits) -> void
    def apply_group_edits(edits)
      edits.each do |edit|
        row = group_properties.where(group_id: edit.group_id, position: edit.position)
        edit.line ? row.update(line: edit.line) : row.delete
      end
    end

    # Groups rows read whole: the lines and members of every group in
    # `rows`, two reads however many groups there are.
    #: (Array[Hash[Symbol, untyped]] rows) -> Array[Group]
    def load_groups(rows)
      ids = rows.map { it.fetch(:id).to_s }
      lines = group_properties.where(group_id: ids).order(:group_id, :position).all
        .group_by { it.fetch(:group_id).to_s }
      members = group_members.where(group_id: ids).order(:card_id).all
        .group_by { it.fetch(:group_id).to_s }
      rows.map { |row|
        id = row.fetch(:id).to_s
        Group.new(
          id:,
          name: row.fetch(:name)&.to_s,
          label: row.fetch(:label).to_s,
          lines: lines.fetch(id, []).map { it.fetch(:line).to_s },
          members: members.fetch(id, []).map { it.fetch(:card_id).to_s },
        )
      }
    end

    # The id of the `sync:*` group, created on first use. One row
    # because a group's name is unique
    # (db/migrations/008_group_names.rb).
    #: () -> String
    def everyone_group_id
      groups.where(name: Group::EVERYONE).sole.fetch(:id).to_s
    rescue Sequel::NoMatchingRow
      create_group(name: Group::EVERYONE)
    end

    # The group name that puts cards in this login's book alone.
    #: (String login) -> String
    def own_sync_name(login)
      "#{Group::SYNC_PREFIX}#{book_name(login)}"
    end

    #: (String group_id) -> bool
    def sync_group?(group_id)
      Group.sync_name?(groups.where(id: group_id).sole.fetch(:name)&.to_s)
    end

    #: (String group_id, String card_id) -> bool
    def member?(group_id, card_id)
      !group_members.where(group_id:, card_id:).empty?
    end

    # The cards belonging to any of these groups, each once — the
    # members a write to those groups can move.
    #: (Array[String] group_ids) -> Array[String]
    def member_ids(group_ids)
      group_members
        .where(group_id: group_ids)
        .distinct
        .order(:card_id)
        .select(:card_id)
        .map { it.fetch(:card_id).to_s }
    end

    # #contact for the callers to whom no row is not an ordinary answer:
    # it raises Sequel::NoMatchingRow where #contact answers nil. A
    # group_members row names a card by foreign key, so a missing row
    # under #fan_out is the corruption `sole` exists to raise on, and
    # #reid is handed an id its caller says exists.
    #: (String id) -> Contact
    def contact!(id)
      contact_from(cards.where(id:).sole, birthday_of(id), inherited_of(id))
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

    # Every named book, the name keyed by the login whose book it is,
    # for the dump — the one read that wants them all
    # (docs/plans/2026-09-19-books-in-the-dump.md). Ordered here
    # rather than by the caller, the birthdays' arrangement reversed:
    # nothing else reads this, so the order a dumped file needs belongs
    # with the read.
    #: () -> Hash[String, String]
    def all_books
      books.order(:login).all.to_h {
        [it.fetch(:login).to_s, it.fetch(:name).to_s] #: [String, String]
      }
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

    # The content lines a contact inherits, each beside the group
    # lending it — every property of every group it belongs to,
    # nothing of a group that holds nothing, and [] for a contact in no
    # group at all. Ordered by group id and then position, so the
    # composed card is the same bytes every read.
    #: (String id) -> Array[Contact::Inherited]
    def inherited_of(id)
      inheritance(inherited_rows.where(card_id: id).all)
    end

    # Every contact's inheritance in one pass, keyed by card, for the
    # listing reads that compose a whole collection — the same shape as
    # birthdays_by_id, for the same reason. Only a contact with
    # something to inherit appears; the absent key reads as [] at the
    # caller, which is what it means.
    #: () -> Hash[String, Array[Contact::Inherited]]
    def inherited_by_id
      rows = inherited_rows.all
      lenders = groups_by_id(rows.map { it.fetch(:group_id).to_s })
      rows
        .group_by { it.fetch(:card_id).to_s }
        .transform_values { inheritance(it, lenders) }
    end

    # Inherited rows as the model reads them: the group lending each,
    # whole, and the row's position and line.
    #: (Array[Hash[Symbol, untyped]] rows, ?Hash[String, Group] lenders) -> Array[Contact::Inherited]
    def inheritance(rows, lenders = groups_by_id(rows.map { it.fetch(:group_id).to_s }))
      rows.map {
        Contact::Inherited.new(
          group: lenders.fetch(it.fetch(:group_id).to_s),
          position: it.fetch(:position).to_i,
          line: it.fetch(:line).to_s,
        )
      }
    end

    # The groups these ids name, whole and keyed by id; no reads at all
    # for a contact in no group, the common case.
    #: (Array[String] ids) -> Hash[String, Group]
    def groups_by_id(ids)
      return {} if ids.empty?

      load_groups(labeled_groups.where(id: ids.uniq).all).to_h {
        [it.id, it] #: [String, Group]
      }
    end

    # What to call a group on a screen: its name, or its id where it
    # has none (db/migrations/005_group_identity.rb). In SQL rather
    # than in Ruby so that every read of a group — a tag, a heading —
    # is the one answer.
    #: () -> untyped
    def group_label
      Sequel.function(:coalesce, Sequel[:groups][:name], Sequel[:groups][:id])
    end

    # A groups row's own columns and its label, the start of every read
    # that hands out a group, qualified for #group_label's reason: the
    # label is written against the table by name.
    #: () -> Sequel::Dataset
    def labeled_groups
      groups.select(Sequel[:groups][:id], Sequel[:groups][:name], group_label.as(:label))
    end

    # The join both inherited reads walk: a membership to the property
    # it inherits, qualified and ordered so the composition neither
    # depends on what SQLite feels like returning nor trips over the
    # group_id the tables share. Ordered by the group's id rather than
    # its name, because a rename must not move a member's lines and
    # change every etag in the group.
    #: () -> Sequel::Dataset
    def inherited_rows
      group_members
        .join(:group_properties, group_id: :group_id)
        .select(
          Sequel[:group_members][:card_id],
          Sequel[:group_properties][:group_id],
          Sequel[:group_properties][:position],
          Sequel[:group_properties][:line],
        )
        .order(
          Sequel[:group_members][:card_id],
          Sequel[:group_properties][:group_id],
          Sequel[:group_properties][:position],
        )
    end

    # A birthday row read as the model. The shape was validated on the
    # way in, so a row that no longer parses is corruption to raise on
    # rather than quietly drop.
    #: (Hash[Symbol, untyped] row) -> Birthday
    def birthday_from(row)
      Birthday.new(year: row[:year], month: row[:month], day: row[:day])
    end

    # One joined birthday-and-card row as an UpcomingBirthday, or nil
    # for a shape that lands on no calendar day (Birthday#next_on).
    #: (Hash[Symbol, untyped] row, Date today, Array[Contact::Inherited] inherited) -> UpcomingBirthday?
    def upcoming_from(row, today, inherited)
      birthday = birthday_from(row)
      occurs_on = birthday.next_on(today)
      return if occurs_on.nil?

      UpcomingBirthday.new(contact: contact_from(row, birthday, inherited), occurs_on:)
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

    #: (Hash[Symbol, untyped] row) -> GroupChange
    def group_change_from(row)
      detail = JSON.parse(row.fetch(:detail).to_s) #: Hash[String, untyped]
      GroupChange.new(
        sequence: row.fetch(:sequence).to_i,
        group_id: row.fetch(:group_id).to_s,
        action: row.fetch(:action).to_s,
        detail:,
        created_at: row.fetch(:created_at).to_s,
      )
    end
  end
end
