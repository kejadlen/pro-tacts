require "pro_tacts/change_id"
require "pro_tacts/vcard"

module ProTacts
  module Import
    # Writes one card an import has settled on into this server's
    # store, on that card's Save: a minted id and the UID that spells
    # it, then Store#put and Store#regroup into every group the boxes
    # beside it ticked, everyone's book included
    # (docs/plans/2026-09-21-import-a-vcf.md, "Writing them in", which
    # also says why this is not idempotent).
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
      # not exist yet, made here with the card they were asked for. The
      # group for the import is one of the two, whichever it has become
      # by now (Web#import_picker). `everyone` is whether to join
      # `sync:*`, which may not exist yet to have an id, resolved here
      # like a name (the plan's "Writing them in").
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
        # `client: false`, though this is a create: everyone's book is
        # a box here, joined through #regroup with the rest
        # (docs/plans/2026-09-21-import-a-vcf.md, "Writing them in").
        @store.put(id, identified(card, id), client: false)

        # The chosen ids need no resolving, the screen having read
        # them off this same store. Deduplicated because two of these
        # can mean one group — a name typed for a group that the box
        # above it already offers, or everyone's book arriving both
        # ticked and asked for — and a second join of one group would
        # only be asked of Store#add_member to come to nothing.
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
      #: (Store store, String id, VCard card, birthday: Birthday?, addresses: Array[Contact::Address], note: String?, ?joins: Array[String], ?leaves: Array[String], ?named: Array[String]) -> Contact
      def self.update(store, id, card, birthday:, addresses:, note:, joins: [], leaves: [], named: [])
        new(store).update(id, card, birthday, addresses, note, joins, leaves, named)
      end

      #: (String id, VCard card, Birthday? birthday, Array[Contact::Address] addresses, String? note, Array[String] chosen, Array[String] leaving, Array[String] named) -> Contact
      def update(id, card, birthday, addresses, note, chosen, leaving, named)
        @store.save_edit(id, card, birthday:, addresses:, note:)

        join = [*chosen, *named.map { group_id(it) }]
        @store.regroup(id, join: join.uniq, leave: leaving) unless join.empty? && leaving.empty?

        # Read back for #call's reason: the groups moved what it serves.
        @store.contact(id) || raise("#{id} was edited and is not stored")
      end

      private

      # The card under the id it is stored as: the source's UID
      # replaced by the minted id, the shape every other create here
      # writes (Admin::CardForm.new_card; why, the plan's "Writing them
      # in").
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
      # Memoized so that a card given the same name twice reads the
      # list once rather than making the group twice. The choices read,
      # not the whole groups read: the match is on name, and a group's
      # members are no part of it (Store#group_choices).
      #: (String name) -> String
      def group_id(name)
        @group_ids[name] ||= @store.group_choices.find { it.name == name }&.id || @store.create_group(name:)
      end
    end
  end
end
