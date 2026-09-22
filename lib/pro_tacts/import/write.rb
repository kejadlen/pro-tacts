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
      # not do about the rest. Either list, or neither: a card in no
      # group is still in everyone's book (#call).
      #: (Store store, VCard card, ?joins: Array[String], ?named: Array[String]) -> Contact
      def self.call(store, card, joins: [], named: [])
        new(store).call(card, joins, named)
      end

      #: (Store store) -> void
      def initialize(store)
        @store = store
        @group_ids = {} #: Hash[String, String]
      end

      # The card, written as a contact: then its groups, the order a
      # create writes them in — the put makes the contact, and the
      # memberships that follow put it somewhere to be found.
      #: (VCard card, Array[String] chosen, Array[String] named) -> Contact
      def call(card, chosen, named)
        id = ChangeId.mint(ChangeId::CONTACT_LENGTH)
        # `client: true` for what a client's PUT means here: a card this
        # creates joins `sync:*`, or it would be on the server and in
        # nobody's book (docs/plans/2026-09-15-client-creates-join-everyone.md).
        @store.put(id, identified(card, id), client: true)

        # The chosen ids need no resolving, the screen having read
        # them off this same store. Deduplicated because two of these
        # can mean one group — a name typed for a group that the box
        # above it already offers, say — and a membership written
        # twice is a constraint violation rather than a second
        # membership.
        join = [*chosen, *named.map { group_id(it) }]
        @store.regroup(id, join: join.uniq, leave: []) unless join.empty?

        # Read back rather than kept from the put, because the group
        # above moved what the card serves. Nothing can have taken it
        # away in between, so a miss here is a broken assumption rather
        # than a case to handle.
        @store.contact(id) || raise("#{id} was written and is not stored")
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
