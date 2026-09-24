require "pro_tacts/change_id"
require "pro_tacts/vcard"

module ProTacts
  module Import
    # Writes one card an import has settled on into this server's
    # store (docs/plans/2026-09-21-import-a-vcf.md).
    #
    # What arrives here is already what is coming in: the review screen
    # pared each card to the properties this book reads and let the
    # importer edit the result (Vcf.read, Admin::ImportOriginal). So this
    # step adds one thing only, the identity a stored contact has — a
    # minted id, and the UID that spells it — and then makes the two
    # writes a client's PUT and the groups dialog make, Store#put and
    # Store#regroup. It is not a second way to write a card.
    #
    # One card per call, because the walk is one card per Save: a
    # contact is in the book the moment its own screen says so, and an
    # import abandoned halfway keeps everything it had already written
    # (Import::Staged). Nothing here knows about the rest of the file.
    #
    # Every group it joins comes from the boxes beside that card,
    # everyone's book included: an import is a person deciding what
    # their book is made of, and a membership this applied on its own
    # would be one no screen asked for.
    #
    # Not idempotent, and cannot be: a .vcf carries no id this server
    # minted, so a second upload of the same file is a second set of
    # cards. The walk is what stands in for that — a card already
    # saved is a contact, and both its row and its screen lead there
    # rather than back into the editor (Web#open_card).
    class Write
      # @rbs @store: Store
      # @rbs @group_ids: Hash[String, String]

      # The group an import offers to put its arrivals in, named for
      # when it happened: what came in together can be found together,
      # and undone together, without anything having to be recorded
      # about the file it came from.
      #: (?Time now) -> String
      def self.default_group(now = Time.now)
        "import-#{now.utc.strftime("%Y%m%dT%H%M%SZ")}"
      end

      # `joins` is the ids of groups this book already has, as the
      # screen beside this card ticked them. `named` is the same
      # answer in names, for the groups that screen asked for that do
      # not exist yet, made here because here is where the card they
      # were asked for is written. The group for the import is one of
      # the two, whichever it has become by now
      # (Web#import_picker) — nothing here knows it from any other
      # answer, there being nothing this can do about it that it does
      # not do about the rest.
      #
      # `everyone` is the one that cannot ride in either list on the
      # screen where it matters most: the first card into an empty
      # book is the write that creates `sync:*`, so there is no id to
      # tick and no row to have unticked. It arrives as the answer
      # rather than as a group, and is resolved here like a name.
      #: (Store store, VCard card, ?joins: Array[String], ?named: Array[String], ?everyone: bool) -> Contact
      def self.call(store, card, joins: [], named: [], everyone: true)
        new(store).call(card, joins, named, everyone)
      end

      #: (Store store) -> void
      def initialize(store)
        @store = store
        @group_ids = {} #: Hash[String, String]
      end

      # The card, written as a contact: then its groups, the order a
      # create writes them in — the put makes the contact, and the
      # memberships that follow put it somewhere to be found.
      #: (VCard card, Array[String] chosen, Array[String] named, bool everyone) -> Contact
      def call(card, chosen, named, everyone)
        id = ChangeId.mint(ChangeId::CONTACT_LENGTH)
        # `client: false`, though this is a create and a client's own
        # create joins `sync:*` for it
        # (docs/plans/2026-09-15-client-creates-join-everyone.md).
        # That flag answers a question the screen beside this card has
        # already asked, and would answer it the one way; here the box
        # is there to be unticked, so the join goes through #regroup
        # with the rest and the answer has somewhere to be no.
        @store.put(id, identified(card, id), client: false)

        # The chosen ids need no resolving, the screen having read
        # them off this same store. Deduplicated because two of these
        # can mean one group — a name typed for a group that the box
        # above it already offers, or everyone's book arriving both
        # ticked and asked for — and a membership written twice is a
        # constraint violation rather than a second membership.
        join = [*chosen, *named.map { group_id(it) }]
        join << group_id(Group::EVERYONE) if everyone
        @store.regroup(id, join: join.uniq, leave: []) unless join.empty?

        # Read back rather than kept from the put, because the group
        # above moved what the card serves. Nothing can have taken it
        # away in between, so a miss here is a broken assumption rather
        # than a case to handle.
        @store.contact(id) || raise("#{id} was written and is not stored")
      end

      # The other Save a row can make: its card folded into a contact
      # the book already has, rather than written as a new one
      # (Import::Merge, docs/plans/2026-09-23-merging-on-import.md).
      # The contact editor's own write, Store#save_edit, because this
      # is that contact edited — its id, its UID and its change-log
      # entry stay its own — and then its groups moved the way the
      # groups dialog moves them: `joins` and `leaves` are what the
      # boxes beside it changed, `named` the groups they asked to be
      # made.
      #: (Store store, String id, VCard card, birthday: Birthday?, ?joins: Array[String], ?leaves: Array[String], ?named: Array[String]) -> Contact
      def self.update(store, id, card, birthday:, joins: [], leaves: [], named: [])
        new(store).update(id, card, birthday, joins, leaves, named)
      end

      #: (String id, VCard card, Birthday? birthday, Array[String] chosen, Array[String] leaving, Array[String] named) -> Contact
      def update(id, card, birthday, chosen, leaving, named)
        @store.save_edit(id, card, birthday:)

        join = [*chosen, *named.map { group_id(it) }]
        @store.regroup(id, join: join.uniq, leave: leaving) unless join.empty? && leaving.empty?

        # Read back for #call's reason: the groups moved what it serves.
        @store.contact(id) || raise("#{id} was edited and is not stored")
      end

      private

      # The card under the id it is stored as. The source's UID goes
      # and the minted id takes its place, the shape every other create
      # here writes (Admin::CardForm.new_card) and the one rake
      # contacts:reid exists to restore: a UID from the book this file
      # was exported from names a record on some other server, and
      # keeping it would leave a contact with two spellings of who it
      # is.
      #: (VCard card, String id) -> VCard
      def identified(card, id)
        _, rest = card.extract("UID")
        rest.insert(["UID:#{id}\r\n"])
      end

      # Looked up before it is made, so a card naming a group this
      # server already has joins that one rather than colliding with
      # its name (db/migrations/008_group_names.rb). That is also what
      # carries the group for the import across the walk: the first
      # Save makes it, and from then on it is an ordinary box.
      #
      # The lookup is per name rather than a list read once up front,
      # because the put above makes a group of its own: the first card
      # into an empty store creates `sync:*` (Store#everyone_group_id),
      # and a list read before that would send this to create it again.
      # Memoized so that a card given the same name twice reads the
      # list once rather than making the group twice. The choices read, not the whole groups read:
      # the match is on name, and a group's members are no part of it
      # (Store#group_choices).
      #: (String name) -> String
      def group_id(name)
        @group_ids[name] ||= @store.group_choices.find { it.name == name }&.id || @store.create_group(name:)
      end
    end
  end
end
