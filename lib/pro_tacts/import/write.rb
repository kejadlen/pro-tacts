require "pro_tacts/change_id"
require "pro_tacts/vcard"

module ProTacts
  module Import
    # Writes the cards an import has settled on into this server's
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
    # Not idempotent, and cannot be: a .vcf carries no id this server
    # minted, so a second upload of the same file is a second set of
    # cards. The review screen is what stands in for that — it says how
    # many contacts are about to be written before any of them are.
    class Write
      # @rbs @store: Store
      # @rbs @group: String?
      # @rbs @joins: Array[Array[String]]
      # @rbs @named: Array[Array[String]]
      # @rbs @group_ids: Hash[String, String]

      # The group an import offers to put its arrivals in, named for
      # when it happened: what came in together can be found together,
      # and undone together, without anything having to be recorded
      # about the file it came from.
      #: (?Time now) -> String
      def self.default_group(now = Time.now)
        "import-#{now.utc.strftime("%Y%m%dT%H%M%SZ")}"
      end

      # `group` is a group named rather than chosen — this server's
      # own by that name, or a new one — and it takes in every card,
      # the import being the one thing they all have in common.
      # `joins` is the rest, a card at a time: the ids of groups this
      # book already has, as the walk ticked them contact by contact,
      # in the cards' own order. `named` is the same list in names,
      # for the groups the walk asked for that do not exist yet —
      # made here and not while the walk was going, an abandoned
      # import being the case that argues for waiting. Any of them, or
      # none: a card in no group is still in everyone's book
      # (#contact).
      #: (Store store, Array[VCard] cards, ?group: String?, ?joins: Array[Array[String]], ?named: Array[Array[String]]) -> Array[Contact]
      def self.call(store, cards, group: nil, joins: [], named: [])
        new(store, group:, joins:, named:).call(cards)
      end

      #: (Store store, ?group: String?, ?joins: Array[Array[String]], ?named: Array[Array[String]]) -> void
      def initialize(store, group: nil, joins: [], named: [])
        @store = store
        @group = group
        @joins = joins
        @named = named
        @group_ids = {} #: Hash[String, String]
      end

      #: (Array[VCard] cards) -> Array[Contact]
      def call(cards)
        cards.each_with_index.map { |card, index|
          contact(card, @joins.fetch(index, []), @named.fetch(index, []))
        }
      end

      private

      # One card, written as a contact: then its groups, the order a
      # create writes them in — the put makes the contact, and the
      # memberships that follow put it somewhere to be found.
      #: (VCard card, Array[String] chosen, Array[String] named) -> Contact
      def contact(card, chosen, named)
        id = ChangeId.mint(ChangeId::CONTACT_LENGTH)
        # `client: true` for what a client's PUT means here: a card this
        # creates joins `sync:*`, or it would be on the server and in
        # nobody's book (docs/plans/2026-09-15-client-creates-join-everyone.md).
        @store.put(id, identified(card, id), client: true)

        # Every name is resolved per card rather than up front, for
        # #group_id's reason; the chosen ids need no resolving, the
        # walk having read them off this same store. Deduplicated
        # because two of these can mean one group — a contact's own
        # new group named what the import's group is named, say —
        # and a membership written twice is a constraint violation
        # rather than a second membership.
        group = @group
        join = [*chosen, *named.map { group_id(it) }]
        join << group_id(group) if group
        @store.regroup(id, join: join.uniq, leave: []) unless join.empty?

        # Read back rather than kept from the put, because the group
        # above moved what the card serves. Nothing can have taken it
        # away in between, so a miss here is a broken assumption rather
        # than a case to handle.
        @store.contact(id) || raise("#{id} was written and is not stored")
      end

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

      # Looked up before it is made, so an import naming a group this
      # server already has joins that one rather than colliding with
      # its name (db/migrations/008_group_names.rb).
      #
      # The lookup is per name rather than a list read once up front,
      # because the put above makes a group of its own: the first card
      # into an empty store creates `sync:*` (Store#everyone_group_id),
      # and a list read before that would send this to create it again.
      # Memoized, so four hundred cards under one group name read the
      # list once.
      #: (String name) -> String
      def group_id(name)
        @group_ids[name] ||= @store.all_groups.find { it.name == name }&.id || @store.create_group(name:)
      end
    end
  end
end
