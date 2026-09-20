require "pro_tacts/import/card"
require "pro_tacts/import/plan"

module ProTacts
  module Import
    # Lands a plan's cards in this server's own store, the step the
    # import screen runs on what a browser uploaded
    # (docs/plans/2026-09-20-import-by-upload.md). It writes what
    # `import:execute` used to write over HTTP, through the store
    # rather than through the routes, and lands the same thing: the
    # card the plan's file describes, in the groups that file names.
    #
    # Idempotent, so a plan uploaded twice writes nothing the second
    # time — which is what the upload has in place of the statuses
    # `execute` recorded, there being no plan on this side to record
    # one in.
    class Land
      # @rbs @store: Store
      # @rbs @group_ids: Hash[String, String]

      # One card's arrival: the contact as it now stands, and whether
      # this upload is what put it there. `stored` false is a card
      # already here — a re-upload, or a plan landed once already —
      # left as it is rather than written over, which is what the PUT's
      # `If-None-Match: *` bought before.
      # Signed in sig/pro_tacts/import.rbs, being a Data class.
      # @rbs skip
      Arrival = Data.define(:contact, :stored)

      # The cards by the id each will be stored under, in the order
      # they should land.
      #: (Store store, Hash[String, Card] cards) -> Array[Arrival]
      def self.call(store, cards)
        new(store).call(cards)
      end

      #: (Store store) -> void
      def initialize(store)
        @store = store
        @group_ids = {} #: Hash[String, String]
      end

      #: (Hash[String, Card] cards) -> Array[Arrival]
      def call(cards)
        cards.map { |id, card| land(id, card) }
      end

      private

      # A card, then its groups, the order `execute` wrote them in: the
      # PUT creates, and the membership that follows is what puts the
      # card in its books.
      #: (String id, Card card) -> Arrival
      def land(id, card)
        stored = @store.contact(id).nil?
        # `client: true` for what a client's PUT means here: a card this
        # creates joins `sync:*`, or it would be on the server and in
        # nobody's book (docs/plans/2026-09-15-client-creates-join-everyone.md).
        # The arrival reports at the PUT (Web#report_broken_assumptions)
        # have nothing to say about a card this built: its lines come
        # from Admin::CardForm, the editor's own writer, not off a wire.
        @store.put(id, card.contact(id).vcard, client: true) if stored

        named = card.groups.uniq.map { group_id(it) }
        # Out of everyone's book unless the file names it, the same
        # reading of a card's groups the browser's own save makes
        # (Web#apply_groups, whose `was` the import filled with this).
        everyone = group_id(Plan::EVERYONE)
        @store.regroup(id, join: named, leave: named.include?(everyone) ? [] : [everyone])

        # Read back rather than kept from the put, because the groups
        # above moved what the card serves. Nothing can have taken it
        # away in between, so a miss here is a broken assumption rather
        # than a case to handle.
        contact = @store.contact(id) || raise("#{id} was landed and is not stored")
        Arrival.new(contact:, stored:)
      end

      # Looked up before it is made, so a plan naming a group this
      # server already has joins that one rather than colliding with
      # its name (db/migrations/008_group_names.rb) — Execute's own
      # shape, and for its reason.
      #
      # The lookup is per name rather than a list read once up front,
      # because the put above makes a group of its own: the first card
      # into an empty store creates `sync:*` (Store#everyone_group_id),
      # and a list read before that would send this to create it again.
      # Memoized, so a plan of four hundred cards under three group
      # names reads the list three times.
      #: (String name) -> String
      def group_id(name)
        @group_ids[name] ||= @store.all_groups.find { it.name == name }&.id || @store.create_group(name:)
      end
    end
  end
end
