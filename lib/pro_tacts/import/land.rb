require "pro_tacts/change_id"
require "pro_tacts/import/vcf"
require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  module Import
    # Lands an uploaded .vcf's cards in this server's store, with the
    # importer's decisions applied on the way in
    # (docs/plans/2026-09-21-import-a-vcf.md).
    #
    # A card arrives a card and is stored as one: nothing here rebuilds
    # it out of fields, so a property this address book has never heard
    # of is kept by default and served back byte for byte (RFC 6352
    # section 6.3.2.2, and VCard's whole posture). What the review
    # screen collects is the exception to that — the handful of
    # properties the importer would rather drop, or read under the
    # note — and this is where those are spent.
    #
    # It writes through Store#put and Store#regroup rather than through
    # the routes those sit behind, so it is not a second way to write a
    # card: it is the same two writes a client's PUT and the groups
    # dialog make.
    #
    # Not idempotent, and cannot be: a .vcf carries no id this server
    # minted, so a second upload of the same file is a second set of
    # cards. The review screen is what stands in for that — it says how
    # many contacts are about to land before any of them do.
    class Land
      # @rbs @store: Store
      # @rbs @decisions: Hash[String, String]
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

      # `decisions` is Vcf::CHOICES by property name, upper case, as
      # Vcf#unknown names them; a property missing from it is kept.
      # `group` is the group every arrival joins, or none.
      #: (Store store, Array[VCard] cards, decisions: Hash[String, String], ?group: String?) -> Array[Contact]
      def self.call(store, cards, decisions:, group: nil)
        new(store, decisions:, group:).call(cards)
      end

      #: (Store store, decisions: Hash[String, String], ?group: String?) -> void
      def initialize(store, decisions:, group: nil)
        @store = store
        @decisions = decisions
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
        @store.put(id, identified(decide(card), id), client: true)

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

      # The card with the importer's decisions spent on it: the lines
      # they dropped gone, the lines they sent to the note gone from
      # where they were and written under it, and everything else —
      # every known property, and every unknown one they kept — exactly
      # as it arrived, bytes and all.
      #: (VCard card) -> VCard
      def decide(card)
        lines = card.lines
        orphaned = orphaned_groups(lines)
        notes = [] #: Array[String]
        kept = [] #: Array[String]

        lines.each do |line|
          property = line.property
          # A blank line, or one that would not read: there is no field
          # to have made a decision about, and the bytes travel
          # (VCard::Parser's own posture).
          if property.nil?
            kept << line.verbatim
            next
          end

          choice = choice_for(property)
          notes << noted(property, lines) if choice == Vcf::NOTE
          next unless choice == Vcf::KEEP
          # A label whose line is gone names nothing, so it goes too.
          next if orphaned.include?(property.group)

          kept << line.verbatim
        end

        noted_into(VCard.new(kept.join), notes)
      end

      # What the importer asked for this property. Anything they were
      # not asked about — every known property — is kept, which is also
      # what an unknown one gets when the form sent no answer for it
      # (Web#decisions_in).
      #: (VCard::Parser::Property property) -> String
      def choice_for(property)
        @decisions.fetch(property.name.upcase, Vcf::KEEP)
      end

      # The group prefixes (`item1.`) whose every line but the label is
      # leaving. Apple hangs a label off the line it names rather than
      # inside it, so dropping `item3.X-ABRELATEDNAMES` without this
      # would leave `item3.X-ABLabel:_$!<Spouse>!$_` behind, naming a
      # line that is no longer there.
      #: (Array[VCard::Parser::Line] lines) -> Array[String]
      def orphaned_groups(lines)
        anchored = {} #: Hash[String, bool]
        lines.each do |line|
          property = line.property
          next if property.nil?

          group = property.group
          next if group.nil? || property.name.casecmp?(Vcf::LABEL)

          anchored[group] = anchored.fetch(group, false) || choice_for(property) == Vcf::KEEP
        end
        anchored.reject { |_group, kept| kept }.keys
      end

      # One line as a note reads it: what it was called, then what it
      # said.
      #: (VCard::Parser::Property property, Array[VCard::Parser::Line] lines) -> String
      def noted(property, lines)
        "#{label_for(property, lines)}: #{property.text.strip}"
      end

      # What to call a value under the note: the row's own label when
      # Contacts wrote one beside it, unwrapped the way every other
      # reader here unwraps one (VCard.unwrap), and the property's name
      # when there is none. "Spouse: Jane" is the point of the choice;
      # "X-ABRELATEDNAMES: Jane" would be a property name in the one
      # place nobody wanted to read one.
      #: (VCard::Parser::Property property, Array[VCard::Parser::Line] lines) -> String
      def label_for(property, lines)
        group = property.group
        label = group && lines.filter_map { it.property }
          .find { it.group == group && it.name.casecmp?(Vcf::LABEL) }
        label ? VCard.unwrap(label.text) : property.name
      end

      # The noted values under the note the card already carries, one
      # to a line. Read, joined, and re-escaped rather than spliced: a
      # NOTE's value is escaped text (RFC 2426 section 3.6.2), so the
      # line break between two of them is a `\n` in the value and not a
      # line break in the card.
      #: (VCard card, Array[String] notes) -> VCard
      def noted_into(card, notes)
        return card if notes.empty?

        existing = card.properties.find { it.name.casecmp?("NOTE") }
        text = [existing&.text, *notes].compact.reject(&:empty?).join("\n")
        card.replace("NOTE", ["NOTE:#{VCard.escape(text)}\r\n"])
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
