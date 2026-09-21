require "pro_tacts/change_id"
require "pro_tacts/vcard"

module ProTacts
  module Import
    # Lands the cards an import has settled on in this server's store
    # (docs/plans/2026-09-21-import-a-vcf.md).
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
    # many contacts are about to land before any of them do.
    class Land
      # @rbs @store: Store
      # @rbs @group: String?
      # @rbs @group_ids: Hash[String, String]

      # The group an import offers to put its arrivals in, named for
      # when it happened: what landed together can be found together,
      # and undone together, without anything having to be recorded
      # about the file it came from.
      #: (?Time now) -> String
      def self.default_group(now = Time.now)
        "import-#{now.utc.strftime("%Y%m%dT%H%M%SZ")}"
      end

      # `group` is the group every arrival joins, or none.
      #: (Store store, Array[VCard] cards, ?group: String?) -> Array[Contact]
      def self.call(store, cards, group: nil)
        new(store, group:).call(cards)
      end

      #: (Store store, ?group: String?) -> void
      def initialize(store, group: nil)
        @store = store
        @group = group
        @group_ids = {} #: Hash[String, String]
      end

      #: (Array[VCard] cards) -> Array[Contact]
      def call(cards)
        cards.map { land(it) }
      end

      private

      # A card, then its group, the order a create writes them in: the
      # put makes the contact, and the membership that follows puts it
      # somewhere to be found.
      #: (VCard card) -> Contact
      def land(card)
        id = ChangeId.mint(ChangeId::CONTACT_LENGTH)
        # `client: true` for what a client's PUT means here: a card this
        # creates joins `sync:*`, or it would be on the server and in
        # nobody's book (docs/plans/2026-09-15-client-creates-join-everyone.md).
        @store.put(id, identified(card, id), client: true)

        group = @group
        @store.regroup(id, join: [group_id(group)], leave: []) if group

        # Read back rather than kept from the put, because the group
        # above moved what the card serves. Nothing can have taken it
        # away in between, so a miss here is a broken assumption rather
        # than a case to handle.
        @store.contact(id) || raise("#{id} was landed and is not stored")
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
