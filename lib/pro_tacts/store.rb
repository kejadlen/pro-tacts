require "date"
require "digest"
require "json"
require "pathname"
require "sequel"

require "pro_tacts/admin/search"
require "pro_tacts/birthday"
require "pro_tacts/card_diff"
require "pro_tacts/change_id"
require "pro_tacts/contact"
require "pro_tacts/edited_contact"
require "pro_tacts/group"
require "pro_tacts/listed_contact"
require "pro_tacts/listed_group"
require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

Sequel.extension :migration

module ProTacts
  # The transactional store: one SQLite database holding each contact's
  # card exactly as it was submitted.
  #
  # Eight kinds of state live here and they are not equally precious.
  # Only the entities, the cards, the change log, the birthdays, the
  # groups, the books, the group change log, and the group photos
  # cannot be rebuilt, and each is argued where it was decided: the
  # entities in db/migrations/016_entities.rb, the cards and the log in
  # docs/plans/2026-08-25-sqlite-schema.md,
  # "What the tables are for", the birthdays in
  # docs/plans/2026-08-31-partial-birthdays.md, the groups in
  # docs/plans/2026-08-24-vcard-storage-and-groups.md, the books in
  # docs/plans/2026-09-19-books-in-the-dump.md, the group change log
  # in docs/plans/2026-09-23-group-change-log.md, the group photos in
  # docs/plans/2026-10-12-group-photos.md. Everything else
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
  # Its Data classes, which the inline syntax cannot read, are signed in
  # sig/pro_tacts/store.rbs.
  class Store
    # @rbs @database: Sequel::Database

    # One entry in the change log: what happened to a card, what it
    # hashed to afterwards, and which of its lines the write moved.
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
    # delete's tombstone carrying the whole group.
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

    # stored cards by id, the birthdays by card id, the groups, their
    # photos by group id, and the books — the name each named one goes
    # by, keyed by login. What `rake db:dump` writes (tasks/db.rake).
    # @rbs skip
    Snapshot = Data.define(:cards, :birthdays, :groups, :group_photos, :books)

    # A group as a picker names it: enough to show it and to submit it,
    # and no more. A Group carries the lines it lends and the ids of
    # its members, two reads beyond the group row itself (#load_groups);
    # a picker is a list of names to tick and needs neither, so
    # #group_choices reads only the row and a count of who is in it,
    # which the import's picker sorts by (Admin::ImportGroups). The
    # label is the same SQL one (#group_label), so a choice and a tag
    # never disagree about what to call a nameless group.
    # @rbs skip
    GroupChoice = Data.define(:id, :name, :label, :member_count)

    # Reopened rather than defined in a block, Group's own reason.
    class GroupChoice
      # Group#sync?'s question, over the lighter row a picker holds.
      #: () -> bool
      def sync?
        Group.sync_name?(name)
      end

      # Group#<=>'s order spelled again for the pickers that sort
      # choices; keep the two alike.
      #: (GroupChoice other) -> Integer?
      def <=>(other)
        [sync? ? 0 : 1, name.nil? ? 1 : 0, label.downcase, id] <=>
          [other.sync? ? 0 : 1, other.name.nil? ? 1 : 0, other.label.downcase, other.id]
      end
    end

    # SQLite has no ON UPDATE, so the column default stamps a row on
    # insert and this stamps it again on the way past. Same expression as
    # the migration's, deliberately: the database keeps the clock, so two
    # rows written in one transaction agree.
    NOW = Sequel.lit("strftime('%Y-%m-%dT%H:%M:%fZ', 'now')") #: untyped

    # Every write is short, so a writer that finds the database locked is
    # better off waiting than raising: two requests saving at once is
    # ordinary, and SQLITE_BUSY straight back to the client is not.
    BUSY_TIMEOUT = 5_000 #: Integer

    # A book named `*`, which would be everyone's (#name_book).
    class EveryonesBookName < ArgumentError; end

    # A rename of a group whose name is a book's (#rename_group).
    class SyncGroupRename < ArgumentError; end

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
          group_photos: group_photos.order(:group_id).select_map(:group_id).to_h { |id|
            photo = group_photo(id.to_s) || raise("group #{id}'s photo went missing mid-snapshot")
            [id.to_s, photo] #: [String, ContactDetails::Photo]
          },
          books: all_books,
        )
      end
    end

    # Every contact, or only those of these ids, ordered by id so that a
    # listing does not depend on what SQLite feels like returning. The
    # ids narrow the read itself, so a book or a multiget composes no
    # card it will not serve.
    #: (?Array[String]? ids) -> Array[Contact]
    def contacts(ids = nil)
      birthdays = birthdays_by_id
      own = components_by_card(ids)
      lent = lent_by_card(ids)
      (ids ? cards.where(id: ids) : cards).order(:id).map {
        id = it.fetch(:id).to_s
        addresses, note = own.fetch(id, NO_COMPONENTS)
        contact_from(it, birthdays[id], addresses, note, lent.fetch(id, []))
      }
    end

    # Every contact's id, in #contacts' order, for a caller that only
    # asks which cards exist: no card is read to answer.
    #: () -> Array[String]
    def contact_ids
      cards.order(:id).select_map(:id).map(&:to_s)
    end

    # Every contact, or only those of these ids, as a list shows it
    # (ListedContact), ordered by id like #contacts: the read behind
    # every screen that lists contacts rather than opening one.
    #: (?Array[String]? ids) -> Array[ListedContact]
    def listed_contacts(ids = nil)
      listed_by_id(ids).values
    end

    # Every contact as a list shows it, paired with its card's
    # updated_at, newest first — the read behind any "recently updated"
    # surface, ordered by the column SQLite already stamps rather than
    # by id. Only the contacts of these ids, or the newest few, are
    # built.
    #: (?Array[String]? ids, ?limit: Integer?) -> Array[RecentContact]
    def contacts_by_recency(ids = nil, limit: nil)
      rows = (ids ? cards.where(id: ids) : cards).order(Sequel.desc(:updated_at)).select(:id, :updated_at)
      rows = (limit ? rows.limit(limit) : rows).all
      listed = listed_by_id(limit ? rows.map { it.fetch(:id).to_s } : ids)
      rows.map {
        RecentContact.new(contact: listed.fetch(it.fetch(:id).to_s), updated_at: it.fetch(:updated_at).to_s)
      }
    end

    # Every card's search key by its id, newest first like
    # #contacts_by_recency.
    #: () -> Hash[String, Admin::Search::Key]
    def search_keys_by_recency
      search_keys.join(:cards, id: :card_id).order(Sequel.desc(Sequel[:cards][:updated_at]))
        .select_map([Sequel[:search_keys][:card_id], :key]).to_h { |id, key|
          [id.to_s, Admin::Search::Key.parse(key.to_s)] #: [String, Admin::Search::Key]
        }
    end

    # The collection's content tag: one value that changes when any card
    # is added, removed, or changed and never otherwise, so a client
    # comparing two of them learns whether to resync — never what
    # changed. The change log's sequence is that value, for the one
    # indexed read it costs. It moves on a rewrite that stores identical
    # bytes too: the promise trades a spurious resync — every etag
    # unchanged, nothing fetched — for never missing a change.
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

    # The id a sync token names this database by: a digest of the
    # change log's first entry's created_at, derived rather than stored
    # (docs/plans/2026-09-24-sync-tokens-name-their-database.md, "The
    # token" and "The costs").
    #: () -> String
    def database_id
      first = change_log.order(:sequence).first
      stamp = first.nil? ? "" : first.fetch(:created_at).to_s
      Digest::SHA256.hexdigest(stamp)[0, 16].to_s
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
      coming = birthdays.all.filter_map { |row|
        occurs_on = birthday_from(row).next_on(today)
        pair = [row.fetch(:card_id).to_s, occurs_on] #: [String, Date]
        pair if occurs_on
      }.sort_by { |id, occurs_on| [occurs_on, id] }.first(limit)
      listed = listed_by_id(coming.map(&:first))
      coming.map { |id, occurs_on| UpcomingBirthday.new(contact: listed.fetch(id), occurs_on:) }
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
    # same reason #lent_by_card orders by it. Membership is the whole
    # answer here, so a group that lends nothing appears too, where the
    # lending reads have nothing of it to carry. Off the contact
    # rather than on it: what a group lends is in the card and belongs
    # to the model of one, and which groups a contact is in is a
    # relationship the card never carries.
    #: (String id) -> Array[Group]
    def groups_of(id)
      load_groups(labeled_groups
        .join(:group_members, group_id: :id)
        .where(card_id: id)
        .order(Sequel[:groups][:id])
        .all)
    end

    # #groups_of with each group's first few members listed, for a
    # contact's tags: the `first` of them in Contact#<=>'s order, read
    # off the sort keys (#reindex), so the tag for `sync:*` lists five
    # contacts rather than the whole book to take five from. The order
    # agrees with a list's because the keys are Contact#sort_key and
    # SQLite compares text bytewise, as Ruby does, with the id behind
    # it for a tie.
    #: (String id, first: Integer) -> Array[ListedGroup]
    def listed_groups_of(id, first:)
      groups = groups_of(id)
      member = Sequel[:group_members][:card_id]
      firsts = groups.to_h { |group|
        ids = group_members.join(:sort_keys, card_id: :card_id).where(group_id: group.id)
          .order(:sort_key, member).limit(first).select_map(member).map(&:to_s)
        [group.id, ids] #: [String, Array[String]]
      }
      listed = listed_by_id(firsts.values.flatten.uniq)
      groups.map { listed_group(it, firsts.fetch(it.id).map { listed.fetch(it) }) }
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
    # #rename logs every member for the clients syncing it. A name
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
        rename(group.to_s, own_sync_name(login)) unless group.nil?
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
      parts = EditedContact.new(vcard, before:).decomposed

      # The Contact this returns is the composed one — the lent
      # components put back, read off membership as it stands at this
      # write — and the logged etag is its hash, so a client's token
      # describes the card it downloads. Membership cannot move during
      # a put, so the components either side of it are the one read
      # above.
      lent = before&.lent || [] #: Array[ContactDetails::Lent]
      # Built before the transaction as well as inside it, because its
      # constructor is where an id that could not be served is refused
      # and a refusal from inside a transaction reaches the caller
      # wearing Sequel's own error class. Composition is lazy, so the
      # one the fan-out throws away below cost nothing to make.
      contact = Contact.new(
        id:, stored: parts.stored, birthday: parts.birthday, addresses: parts.addresses, note: parts.note, lent:
      )
      @database.transaction do
        # The groups move first, so that everything composed below is
        # the card this write leaves behind: the etag the change log
        # records is what a client downloading this member now gets,
        # group component included. The fan-out brackets the edits with
        # a read of every other member either side of them.
        unless parts.address_edits.empty? && parts.note_edits.empty?
          groups = (parts.address_edits.map(&:group_id) + parts.note_edits.map(&:group_id)).uniq
          fan_out(member_ids(groups), except: id) {
            apply_address_edits(parts.address_edits)
            apply_note_edits(parts.note_edits)
          }
          contact = Contact.new(
            id:, stored: parts.stored, birthday: parts.birthday, addresses: parts.addresses, note: parts.note,
            lent: lent_of(id)
          )
        end
        upsert_card(contact.id, parts.stored)
        # After the card, which the membership names by foreign key, and
        # before the log entry, which records the card composed with
        # whatever the group lends. The put's entry is the card's arrival
        # in the book, so the join writes none of its own.
        if client && before.nil?
          group_members.insert(group_id: everyone_group_id, card_id: contact.id)
          contact = Contact.new(
            id:, stored: parts.stored, birthday: parts.birthday, addresses: parts.addresses, note: parts.note,
            lent: lent_of(contact.id)
          )
        end
        write_birthday(contact.id, parts.birthday)
        write_components(entity_id_of(contact.id), parts.addresses, parts.note)
        record(
          contact.id,
          action: Action::PUT,
          etag: contact.etag,
          diff: CardDiff.between(before&.vcard, contact.vcard),
        )
        reindex(contact.id, parts.stored, addresses: parts.addresses, note: parts.note)
        contact
      end
    end

    # Why this and #put cannot be one path is
    # docs/plans/2026-09-05-web-card-editor.md, "Two write paths
    # through the store". The card input is the stored one by
    # definition, `birthday:` is the model's whole new state, an
    # upsert or a delete, never a splice
    # (docs/plans/2026-09-07-web-birthday-editor.md), and `addresses:`
    # and `note:` the entity's whole new components, the editor's rows
    # read back (Admin::CardForm). A card rather than its bytes, for
    # #put's reason: the editor spliced one to make this save, and
    # re-reading its bytes here would walk them again to reach what the
    # caller already had.
    #: (String id, VCard vcard, birthday: Birthday?, addresses: Array[ContactDetails::Address], note: String?) -> Contact
    def save_edit(id, vcard, birthday:, addresses:, note:)
      before = contact(id)
      contact = Contact.new(id:, stored: vcard, birthday:, addresses:, note:, lent: lent_of(id))
      @database.transaction do
        upsert_card(contact.id, vcard)
        write_birthday(contact.id, birthday)
        write_components(entity_id_of(contact.id), addresses, note)
        record(
          contact.id,
          action: Action::EDIT,
          etag: contact.etag,
          diff: CardDiff.between(before&.vcard, contact.vcard),
        )
        reindex(contact.id, vcard, addresses:, note:)
      end
      contact
    end

    # Removes a card, leaving the change-log entry that tells a syncing
    # client it is gone. The tombstone carries the whole card away in
    # its diff — every line removed and none added — which is the only
    # record left of what was here, the row itself being gone. The
    # entity goes, and the card and everything keyed by it follow on
    # the cascade (db/migrations/016_entities.rb).
    #: (String id) -> bool
    def delete(id)
      @database.transaction do
        before = contact(id)
        deleted = entities.where(id: cards.where(id:).select(:entity_id)).delete.positive?
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

      # One draw, #new_entity's reason; a collision raises on cards' id.
      new_id = ChangeId.mint(ChangeId::CONTACT_LENGTH)
      # A card with no UID line gains one here, and several collapse
      # to it: #insert lands it before END:VCARD, the envelope's own
      # last word, where every card this server writes leaves it.
      _, rest = before.stored.extract("UID")
      stored = rest.insert(["UID:#{new_id}\r\n"])
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
        search_keys.where(card_id: id).delete
        sort_keys.where(card_id: id).delete
        after = contact!(new_id)
        record(id, action: Action::DELETE, etag: nil, diff: CardDiff.between(before.vcard, nil))
        record(
          new_id,
          action: Action::PUT,
          etag: after.etag,
          diff: CardDiff.between(before.vcard, after.vcard),
        )
        # The entity is the same entity — only the card's href moved —
        # so the components read back off it re-key the search with
        # what they already said.
        addresses, note = components_by_entity(cards.where(id: new_id).sole.fetch(:entity_id).to_s)
        reindex(new_id, stored, addresses:, note:)
      end
      new_id
    end

    # Creates a group and hands back the id it was given. The name is
    # the author's label and optional; a group without one is displayed
    # by its id (#group_label), and the empty string is refused
    # by the schema rather than kept as a second spelling of nameless.
    # Logged in the group's own log as every group write is, the
    # create's detail carrying the name it was created under.
    #
    # The id is its entity's (#new_entity). A taken name raises on the
    # unique index (db/migrations/008_group_names.rb), the caller's to
    # hear.
    #
    # `members` join in the same transaction, for a group made from a
    # contact's card (Web#apply_new_group): a group that exists only
    # once its first member is in it, rather than one left empty and
    # nameless when the join fails.
    #: (?name: String?, ?members: Array[String]) -> String
    def create_group(name: nil, members: [])
      @database.transaction do
        id = new_entity
        groups.insert(id:, name:)
        record_group_change(id, action: GroupAction::CREATE, detail: {"name" => name})
        members.each { add_member(id, it) }
        id
      end
    end

    # Every group, ordered by id — the order #groups_of and the
    # composition both use, so a rename never moves one.
    #: () -> Array[Group]
    def all_groups
      load_groups(labeled_groups.order(:id).all)
    end

    # #all_groups with each group's first few members listed out of a
    # `listing` the caller already read, since `sync:*` would otherwise
    # read the whole book again.
    #: (Array[ListedContact] listing, first: Integer) -> Array[ListedGroup]
    def all_listed_groups(listing, first:)
      sorted = listing.sort
      all_groups.map { |group|
        joined = group.members.to_set
        listed_group(group, sorted.lazy.select { joined.include?(it.id) }.first(first))
      }
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
    # stored as that rather than refused by the schema. A group whose
    # name is a book's keeps it: renaming `sync:*` would tell every
    # client to drop every card, and a login's `sync:` group is named by
    # #name_book, which a rename here would leave naming a group that is
    # not there (docs/plans/2026-09-16-book-names.md). Refused before
    # the transaction, #name_book's reason. A rename into a `sync:` name
    # is how a book is made, and stays.
    #: (String id, name: String?) -> void
    def rename_group(id, name:)
      refuse_sync_rename(id, name)
      rename(id, name)
    end

    # Replaces what a group lends, wholesale: its entity's whole
    # address list at positions from zero, and its note. Every member
    # serves the new components from here on, so every member whose
    # served card moved is logged (#fan_out), and the group's own log
    # carries the lines the write moved in CardDiff's spelling
    # (Group#composed_lines). A pure reorder is an entry with an empty
    # diff — the multiset difference cannot see it, but the lending
    # order moved every member's composed card, so it is a real write.
    # A rewrite that stores the same components in the same order
    # writes no entry, this log's own bargain against the cards' (the
    # plan's "One entry per primitive").
    #: (String id, Array[ContactDetails::Address] addresses, String? note) -> void
    def set_group_components(id, addresses, note)
      @database.transaction do
        was = group_lines(id)
        lines = Group.composed_lines(addresses, note)
        diff = CardDiff.between_lines(was, lines)
        fan_out(member_ids([id])) do
          write_addresses(id, addresses)
          write_note(id, note)
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
    # leaves the group as it was rather than half renamed. Membership
    # is #edit_members', the members screen's own save.
    #: (String id, name: String?, addresses: Array[ContactDetails::Address], note: String?) -> void
    def edit_group(id, name:, addresses:, note:)
      refuse_sync_rename(id, name)
      @database.transaction do
        rename(id, name)
        set_group_components(id, addresses, note)
      end
    end

    # The members screen's save, #regroup's shape over a group: what
    # it toggled rather than the set it shows, one transaction so a
    # failure part-way leaves the membership as it was. Leavers go
    # first and joiners last, so no card is logged for lines it was
    # about to stop or had yet to start serving.
    #: (String id, join: Array[String], leave: Array[String]) -> void
    def edit_members(id, join:, leave:)
      @database.transaction do
        leave.each { remove_member(id, it) }
        join.each { add_member(id, it) }
      end
    end

    # A group's photo, or nil for a group without one. The bytes were
    # judged on the way in (#set_group_photo), so a row that no longer
    # sniffs to an image is corruption to raise on, the birthdays' rule.
    #: (String id) -> ContactDetails::Photo?
    def group_photo(id)
      bytes = group_photos.where(group_id: id).get(:bytes)
      return if bytes.nil?

      Contact.photo_of(bytes.b) or raise "group #{id}'s stored photo sniffs to no image format"
    end

    # Sets a group's photo, replacing any it had. Logged nowhere: the
    # picture is the admin's alone, and the dump is its backup
    # (docs/plans/2026-10-12-group-photos.md).
    #: (String id, ContactDetails::Photo photo) -> void
    def set_group_photo(id, photo)
      group_photos
        .insert_conflict(target: :group_id, update: {bytes: Sequel[:excluded][:bytes]})
        .insert(group_id: id, bytes: Sequel.blob(photo.bytes))
    end

    #: (String id) -> void
    def remove_group_photo(id)
      group_photos.where(group_id: id).delete
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
      # A plain `first` read rather than #group's rescued `sole`: a
      # rescue around the whole method would swallow a NoMatchingRow
      # raised from inside the transaction below and answer it as an
      # ordinary miss. id is the primary key, so there is no ambiguity
      # for `sole` to catch.
      row = groups.where(id:).first
      return false if row.nil?

      name = row.fetch(:name).to_s
      # Refused before the transaction, #name_book's reason for the
      # same refusal: Sequel wraps what a rollback raises.
      raise EveryonesBookName, "#{Group::EVERYONE} is everyone's book, not a group to delete" if name == Group::EVERYONE

      @database.transaction do
        group = load_groups([labeled_groups.where(id:).sole]).fetch(0)
        members = member_ids([id])
        record_group_change(
          id,
          action: GroupAction::DELETE,
          detail: {"name" => row.fetch(:name), "lines" => group.composed_lines, "members" => members},
        )
        fan_out(members, moved: Group.sync_name?(name) ? members : []) {
          entities.where(id:).delete
        }
        true
      end
    end

    # A card's side of #edit_members: one transaction, leavers first and
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

    # Drops the index and derives it again from the stored cards and
    # the components beside them. Always safe to run: nothing is
    # authoritative here, so if the projection ever disagrees with
    # what is stored, this is the repair. Raw rows rather than
    # #contacts, which compose lent components too: the index reflects
    # what is stored (#reindex).
    #: () -> void
    def rebuild_index
      @database.transaction do
        card_properties.delete
        search_keys.delete
        sort_keys.delete
        cards.order(:id).all.each do
          id = it.fetch(:id).to_s
          addresses, note = components_by_entity(it.fetch(:entity_id).to_s)
          reindex(id, VCard.new(it.fetch(:vcard).to_s), addresses:, note:)
        end
      end
    end

    private

    #: () -> Sequel::Dataset
    def entities
      @database[:entities]
    end

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
    def search_keys
      @database[:search_keys]
    end

    #: () -> Sequel::Dataset
    def sort_keys
      @database[:sort_keys]
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
    def addresses_dataset
      @database[:addresses]
    end

    #: () -> Sequel::Dataset
    def notes
      @database[:notes]
    end

    #: () -> Sequel::Dataset
    def group_photos
      @database[:group_photos]
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
      return if cards.where(id:).update(vcard: vcard.to_s, updated_at: NOW).positive?

      cards.insert(entity_id: new_entity, id:, vcard: vcard.to_s)
    end

    # An entity under a freshly minted id, for a card or a group to
    # take. One draw: at 2^48 a collision is a broken generator, and
    # the primary key's raise says so.
    #: () -> String
    def new_entity
      id = ChangeId.mint(ChangeId::ENTITY_LENGTH)
      entities.insert(id:)
      id
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

    # #rename_group's refusal, for it and for #edit_group, which renames
    # inside a transaction of its own and so has to ask before opening
    # it.
    #: (String id, String? name) -> void
    def refuse_sync_rename(id, name)
      was = groups.where(id:).sole.fetch(:name)&.to_s
      renamed = was != group_name(name)
      raise SyncGroupRename, "#{was} is a book's group, named by the book" if renamed && Group.sync_name?(was)
    end

    # The rename itself, with no refusal: #name_book's way of renaming
    # the one group #rename_group will not. A name is on no card, so no
    # member's bytes move, but a `sync:` name is what puts a card in a
    # book: a rename into, out of, or between them moves every member
    # between books and logs each one (#fan_out's `moved`). Logged in
    # the group's own log only where the name moved, the log recording
    # what happened rather than that a save was asked
    # (docs/plans/2026-09-23-group-change-log.md, "One entry per
    # primitive").
    #: (String id, String? name) -> void
    def rename(id, name)
      name = group_name(name)
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

    # A name as a group stores it: a blank is NULL, nameless's one
    # spelling (db/migrations/005_group_identity.rb).
    #: (String? name) -> String?
    def group_name(name)
      name unless name.to_s.strip.empty?
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

    # The group's rows as the address edits asked for them: each edit
    # names a position in the list the member was lent (Group#addresses
    # in order), rewrites the address there, or removes the row where
    # the member deleted what it lent. The list is written back whole,
    # so the positions stay contiguous and a later edit's position is
    # always the index a member reads.
    #: (Array[EditedContact::AddressEdit] edits) -> void
    def apply_address_edits(edits)
      edits.group_by(&:group_id).each do |group_id, group_edits|
        list = addresses_of(group_id) #: Array[ContactDetails::Address?]
        group_edits.each { list[it.position] = it.address }
        write_addresses(group_id, list.compact)
      end
    end

    # The note edits' half of #apply_address_edits: one row per group,
    # upserted or gone.
    #: (Array[EditedContact::NoteEdit] edits) -> void
    def apply_note_edits(edits)
      edits.each do |edit|
        if edit.text
          write_note(edit.group_id, edit.text)
        else
          notes.where(entity_id: edit.group_id).delete
        end
      end
    end

    # Groups rows read whole: the components and members of every
    # group in `rows`, and which have a photo, four reads however many
    # groups there are. The photo read takes ids, never bytes.
    #: (Array[Hash[Symbol, untyped]] rows) -> Array[Group]
    def load_groups(rows)
      ids = rows.map { it.fetch(:id).to_s }
      addresses = addresses_dataset.where(entity_id: ids).order(:entity_id, :position).all
        .group_by { it.fetch(:entity_id).to_s }
      group_notes = notes.where(entity_id: ids).all.to_h {
        pair = [it.fetch(:entity_id).to_s, it.fetch(:text).to_s] #: [String, String]
        pair
      }
      members = group_members.where(group_id: ids).order(:card_id).all
        .group_by { it.fetch(:group_id).to_s }
      photos = group_photos.where(group_id: ids).select_map(:group_id).map(&:to_s)
      rows.map { |row|
        id = row.fetch(:id).to_s
        Group.new(
          id:,
          name: row.fetch(:name)&.to_s,
          label: row.fetch(:label).to_s,
          addresses: addresses.fetch(id, []).map { address_from(it) },
          note: group_notes[id],
          members: members.fetch(id, []).map { it.fetch(:card_id).to_s },
          photo: photos.include?(id),
        )
      }
    end

    #: (Group group, Array[ListedContact] first_members) -> ListedGroup
    def listed_group(group, first_members)
      ListedGroup.new(
        id: group.id, name: group.name, label: group.label, addresses: group.addresses, note: group.note,
        members: group.members, photo: group.photo, first_members:,
      )
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
      addresses, note = components_by_card([id]).fetch(id, NO_COMPONENTS)
      contact_from(cards.where(id:).sole, birthday_of(id), addresses, note, lent_of(id))
    end

    # Replaces a card's rows in the index. Rebuilt wholesale rather than
    # diffed because it is derived data and replacing it is the cheaper
    # correct thing. Indexes the lines that read and says nothing about
    # the ones that did not: the card is served from its bytes either
    # way, and there is no version of this write that fixes a line the
    # parser cannot read. Takes the stored card — with the birthday
    # and the components already subtracted — beside the entity's own
    # addresses and note, which the search key reads, so the index
    # never sees a BDAY, ADR, or NOTE no stored card carries.
    #: (String id, VCard vcard, addresses: Array[ContactDetails::Address], note: String?) -> void
    def reindex(id, vcard, addresses:, note:)
      # Before the parse, so that a card which has stopped parsing does
      # not keep the rows from when it did.
      card_properties.where(card_id: id).delete
      search_keys.where(card_id: id).delete
      sort_keys.where(card_id: id).delete

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
      contact = Contact.new(id:, stored: vcard, birthday: nil, addresses:, note:, lent: [])
      search_keys.insert(card_id: id, key: Admin::Search.key(contact).to_json)
      sort_keys.insert(card_id: id, sort_key: contact.sort_key)
    end

    # Applies whatever migrations the database has not seen. On one it is
    # already current with, this is a read of Sequel's schema_info table
    # and nothing else, which is cheap enough to do on every open and
    # leaves no way to serve from a database a deploy forgot to migrate.
    #: () -> void
    def migrate
      Sequel::Migrator.run(@database, MIGRATIONS.to_s)
    end

    #: (Hash[Symbol, untyped] row, Birthday? birthday, Array[ContactDetails::Address] addresses, String? note, Array[ContactDetails::Lent] lent) -> Contact
    def contact_from(row, birthday, addresses, note, lent)
      Contact.new(
        id: row.fetch(:id).to_s,
        stored: VCard.new(row.fetch(:vcard).to_s),
        birthday:,
        addresses:,
        note:,
        lent:,
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

    # The empty half of #components_by_card's answer, for the cards a
    # caller reads that hold neither an address nor a note.
    NO_COMPONENTS = [[], nil] #: [Array[ContactDetails::Address], String?]

    # The index's reading of these cards, or of every card, keyed by id
    # in id order: each card written back out of its indexed lines with
    # the PHOTO left out, and composed as #contacts composes the stored
    # one, so a list reads the same names, numbers and lent lines a
    # contact's page does without reading a picture to show a name. The
    # index holds what #reindex read off the stored card, and a line
    # that would not read is in neither. Each line keeps the property
    # it was written from as its reading (VCard.of), so the card is not
    # parsed back into what the rows already said. Of a PHOTO, the
    # first characters alone, which is all Contact.photo_head? decodes.
    #: (Array[String]? ids) -> Hash[String, ListedContact]
    def listed_by_id(ids)
      scope = ids ? card_properties.where(card_id: ids) : card_properties
      lines = scope.exclude(name: "PHOTO").order(:card_id, :position).all.group_by { it.fetch(:card_id).to_s }
      parameters = (ids ? card_parameters.where(card_id: ids) : card_parameters)
        .order(:card_id, :position, Sequel.lit("rowid")).all
        .group_by { "#{it.fetch(:card_id)} #{it.fetch(:position)}" }
      # Latest position first, so the to_h below keeps each card's
      # first PHOTO: the one Contact#photo reads.
      heads = scope.where(name: "PHOTO").order(:card_id, Sequel.desc(:position))
        .select(:card_id, Sequel.function(:substr, :value, 1, Contact::PHOTO_HEAD).as(:head)).all
        .to_h {
          [it.fetch(:card_id).to_s, it.fetch(:head).to_s] #: [String, String]
        }
      birthdays = birthdays_by_id
      own = components_by_card(ids)
      lent = lent_by_card(ids)
      (ids ? cards.where(id: ids) : cards).order(:id).select_map(:id).to_h { |raw|
        id = raw.to_s
        read = lines.fetch(id, []).map { |row|
          pairs = parameters.fetch("#{id} #{row.fetch(:position)}", []).map {
            [it.fetch(:name).to_s, it.fetch(:value).to_s] #: [String, String]
          }
          property = VCard::Parser::Property.new(
            group: row.fetch(:property_group)&.to_s, name: row.fetch(:name).to_s, parameters: pairs, value: row.fetch(:value).to_s,
          )
          VCard::Parser::Line.new(property:, verbatim: "#{VCard.header_of(property)}#{property.value}\r\n", error: nil)
        }
        addresses, note = own.fetch(id, NO_COMPONENTS)
        contact = Contact.new(
          id:, stored: VCard.of(read), birthday: birthdays[id], addresses:, note:, lent: lent.fetch(id, [])
        )
        head = heads[id]
        listed = ListedContact.new(contact, photo: !head.nil? && Contact.photo_head?(head))
        [id, listed] #: [String, ListedContact]
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

    # One card's birthday, or nil for none — the ordinary answer, a
    # birthday being optional, so it is rescued here, #contact's shape.
    #: (String id) -> Birthday?
    def birthday_of(id)
      birthday_from(birthdays.where(card_id: id).sole)
    rescue Sequel::NoMatchingRow
      nil
    end

    # The components a contact's groups lend it, each beside the group
    # lending them — every address and note of every group it belongs
    # to that holds either, and [] for a contact no lender reaches.
    # Ordered by group id and then position, so the composed card is
    # the same bytes every read. A group's addresses carry their
    # positions as their indices, the positions the writes keep
    # contiguous (#apply_address_edits).
    #: (String id) -> Array[ContactDetails::Lent]
    def lent_of(id)
      lent_by_card([id]).fetch(id, [])
    end

    # The components every contact's groups lend it, keyed by card, for
    # the reads that compose a whole collection — the same shape as
    # birthdays_by_id, for the same reason. Only a contact a lender
    # reaches appears; the absent key reads as [] at the caller, which
    # is what it means. Ordered by the group's id rather than its name,
    # because a rename must not move a member's components and change
    # every etag in the group.
    #: (Array[String]? ids) -> Hash[String, Array[ContactDetails::Lent]]
    def lent_by_card(ids)
      members = (ids ? group_members.where(card_id: ids) : group_members).order(:card_id, :group_id).all
      lenders = groups_by_id(members.map { it.fetch(:group_id).to_s })
      members.group_by { it.fetch(:card_id).to_s }.transform_values { |rows|
        rows.filter_map { |row|
          group = lenders.fetch(row.fetch(:group_id).to_s)
          next if group.addresses.empty? && group.note.nil?

          Contact::Lent.new(
            group:,
            addresses: group.addresses.each_with_index.map { |address, position|
              Contact::LentAddress.new(position:, address:)
            },
            note: group.note,
          )
        }
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

    # The addresses and note an entity holds, in one pair of reads —
    # a card's own components, read beside the row by the reads that
    # rebuild rather than compose (#rebuild_index).
    #: (String entity_id) -> [Array[ContactDetails::Address], String?]
    def components_by_entity(entity_id)
      addresses = addresses_dataset.where(entity_id:).order(:position).all.map { address_from(it) }
      note = notes.where(entity_id:).get(:text)&.to_s
      [addresses, note]
    end

    # #components_by_entity over cards, keyed by card id: the joins a
    # whole-collection read makes once, rather than a pair of reads per
    # card. Only a card with an address appears in the first hash and
    # one with a note in the second; the absent key reads as none.
    #: (Array[String]? ids) -> Hash[String, [Array[ContactDetails::Address], String?]]
    def components_by_card(ids)
      scope = ids ? cards.where(id: ids) : cards
      addresses = scope.join(:addresses, entity_id: :entity_id)
        .order(Sequel[:cards][:id], :position)
        .select(Sequel[:cards][:id], :po_box, :extended, :street, :locality, :region, :postal_code, :country, :label)
        .all
        .group_by { it.fetch(:id).to_s }
        .transform_values { |rows| rows.map { address_from(it) } }
      note_rows = notes.join(:cards, entity_id: :entity_id).select(Sequel[:cards][:id], :text)
      note_rows = note_rows.where(Sequel[:cards][:id] => ids) if ids
      notes_by_card = note_rows.all.to_h {
        pair = [it.fetch(:id).to_s, it.fetch(:text).to_s] #: [String, String]
        pair
      }
      scope.select_map(:id).to_h { |raw|
        id = raw.to_s
        [id, [addresses.fetch(id, []), notes_by_card[id]]] #: [String, [Array[ContactDetails::Address], String?]]
      }
    end

    # An address row as the model reads it. The columns were written
    # through the model on the way in, so a row that no longer reads
    # is corruption to raise on rather than quietly drop, the
    # birthdays' rule.
    #: (Hash[Symbol, untyped] row) -> ContactDetails::Address
    def address_from(row)
      Contact::Address.new(
        po_box: row.fetch(:po_box).to_s,
        extended: row.fetch(:extended).to_s,
        street: row.fetch(:street).to_s,
        locality: row.fetch(:locality).to_s,
        region: row.fetch(:region).to_s,
        postal_code: row.fetch(:postal_code).to_s,
        country: row.fetch(:country).to_s,
        label: row[:label]&.to_s,
      )
    end

    # The entity behind a card, read where a write needs it once the
    # card row exists (#put, #save_edit). The entity was minted with
    # the card (db/migrations/016_entities.rb), so a miss is the
    # corruption `sole` exists to raise on.
    #: (String id) -> String
    def entity_id_of(id)
      cards.where(id:).sole.fetch(:entity_id).to_s
    end

    # The entity's whole new address list, at positions from zero, and
    # its note — the write half of #components_by_entity, for a card's
    # own entity (#put, #save_edit) and a group's
    # (#set_group_components). A nil note is the row gone: the note is
    # one or none, never emptied.
    #: (String entity_id, Array[ContactDetails::Address] addresses, String? note) -> void
    def write_components(entity_id, addresses, note)
      write_addresses(entity_id, addresses)
      write_note(entity_id, note)
    end

    #: (String entity_id, Array[ContactDetails::Address] addresses) -> void
    def write_addresses(entity_id, addresses)
      addresses_dataset.where(entity_id:).delete
      addresses.each.with_index do |address, position|
        addresses_dataset.insert(
          entity_id:,
          position:,
          po_box: address.po_box,
          extended: address.extended,
          street: address.street,
          locality: address.locality,
          region: address.region,
          postal_code: address.postal_code,
          country: address.country,
          label: address.label,
        )
      end
    end

    #: (String entity_id, String? note) -> void
    def write_note(entity_id, note)
      if note
        notes
          .insert_conflict(target: :entity_id, update: {text: Sequel[:excluded][:text]})
          .insert(entity_id:, text: note)
      else
        notes.where(entity_id:).delete
      end
    end

    # An entity's addresses in order — the list an AddressEdit's
    # positions name (#apply_address_edits).
    #: (String entity_id) -> Array[ContactDetails::Address]
    def addresses_of(entity_id)
      addresses_dataset.where(entity_id:).order(:position).all.map { address_from(it) }
    end

    # A group's components as the lines a member's card composes them
    # in, read off the store's rows for the group as it stands — the
    # `was` a #set_group_components write is measured against and a
    # tombstone's detail carries (Group#composed_lines' own shape).
    #: (String id) -> Array[String]
    def group_lines(id)
      load_groups([labeled_groups.where(id:).sole]).fetch(0).composed_lines
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

    # A birthday row read as the model. The shape was validated on the
    # way in, so a row that no longer parses is corruption to raise on
    # rather than quietly drop.
    #: (Hash[Symbol, untyped] row) -> Birthday
    def birthday_from(row)
      Birthday.new(year: row[:year], month: row[:month], day: row[:day])
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
