require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  module Import
    # An uploaded .vcf, read as the cards it holds and as what this
    # server does not recognise in them
    # (docs/plans/2026-09-21-import-a-vcf.md, "What comes in").
    #
    # Two readings: the split into cards, and per card the split #read
    # makes into what is coming in and what is left behind, which the
    # walk strikes on the card as exported (Admin::ImportOriginal) and
    # counts on its row (Admin::ImportSidebar).
    module Vcf
      # A file that is not a set of vCards.
      class Invalid < StandardError; end

      # Apple's own name for a row, carried on a line of its own beside
      # the one it names (`item1.X-ABLabel:_$!<Spouse>!$_`). Known, and
      # named apart from the rest because what happens to the line it
      # annotates happens to it too: a label whose line is gone names
      # nothing (#read).
      LABEL = "X-ABLABEL" #: String

      # The properties this address book reads, and so the properties
      # an import brings in: the envelope, the fields a screen shows
      # (Contact's own readers, and the X-ABLabel that names a row), the
      # two a company card is read by (ORG and X-ABShowAs,
      # docs/plans/2026-09-24-company-cards.md), and BDAY, which the
      # store takes into the model on the way in
      # (docs/plans/2026-09-11-every-birthday-in-the-model.md).
      KNOWN = [
        *%w[BEGIN END VERSION UID N FN NICKNAME BDAY TEL EMAIL IMPP ADR NOTE PHOTO ORG X-ABSHOWAS],
        LABEL,
      ].freeze #: Array[String]

      # Unknown, and not worth saying so: facts about the export rather
      # than the person, still dropped and still struck, but never
      # counted as a loss (docs/plans/2026-09-21-import-a-vcf.md, "What
      # comes in"; SOURCE and REV,
      # docs/plans/2026-09-25-importing-from-monica.md).
      NOISE = %w[PRODID SOURCE REV].freeze #: Array[String]

      # Tags (RFC 2426 section 3.6.1), which come in as groups rather
      # than as a line: the walk ticks a group of each name beside the
      # card (Web#import_picker), so what the line said arrives, and
      # the line itself, struck on the card as exported, is not a loss
      # to count.
      CATEGORIES = "CATEGORIES" #: String

      # What an import makes of one card: the card as it will come in,
      # and the lines it leaves behind. Signed in
      # sig/pro_tacts/import.rbs, being a Data class.
      # @rbs skip
      Reading = Data.define(:card, :dropped)

      # One property the file carries that KNOWN does not name, across
      # every card in it: how many lines wear it, and a few of their
      # real values. Signed in sig/pro_tacts/import.rbs, being a Data
      # class.
      # @rbs skip
      Unknown = Data.define(:name, :count, :examples)

      EXAMPLES = 3 #: Integer

      # Long enough for a line's parameters, short of a photo's payload.
      EXAMPLE_LENGTH = 120 #: Integer

      # The cards a file holds, in the order it wrote them, each as the
      # bytes it arrived in. A card is what lies from BEGIN to END, and
      # the lines between cards are blank or the file is not a set of
      # vCards — refused whole rather than partly imported: a source
      # that will not read brings in nothing. A BEGIN inside a card is
      # refused the same way: vCard 3.0 nests a card only escaped into
      # one AGENT value (RFC 2426 section 3.5.4), so a second BEGIN is
      # a card that never ended, and reading on would fold two people
      # into one.
      #: (String bytes) -> Array[VCard]
      def self.cards(bytes)
        cards = [] #: Array[VCard]
        open = nil #: Array[VCard::Parser::Line]?
        VCard::Parser.lines(bytes).each do |line|
          name = line.property&.name
          if open.nil?
            next if line.verbatim.strip.empty?

            raise Invalid, "a line outside a card: #{summary(line)}" unless name&.casecmp?("BEGIN")

            open = [line]
          else
            raise Invalid, "a card begins inside another: #{summary(line)}" if name&.casecmp?("BEGIN")

            open << line
            next unless name&.casecmp?("END")

            cards << VCard.of(open)
            open = nil
          end
        end
        raise Invalid, "the last card has no END:VCARD" unless open.nil?
        raise Invalid, "this file holds no vCards" if cards.empty?

        refused = cards.reject(&:card?)
        raise Invalid, "#{refused.size} of these are not vCards: BEGIN, VERSION and END are what makes one" if refused.any?

        cards
      end

      # Every property in these cards that KNOWN does not name, by
      # name rather than by the spelling the line wore, so
      # `X-SOCIALPROFILE;type=twitter` is not a second entry from
      # `X-SOCIALPROFILE`. Ordered by name. An unreadable line has no
      # property name and is not among them (#read keeps it).
      #: (Array[VCard] cards) -> Array[Unknown]
      def self.unknown(cards)
        seen = {} #: Hash[String, Array[String]]
        cards.each do |card|
          card.lines.each do |line|
            property = line.property
            next if property.nil?

            name = property.name.upcase
            next if known?(name) || noise?(name) || name == CATEGORIES

            (seen[name] ||= []) << summary(line)
          end
        end
        seen.sort.map { |name, examples|
          Unknown.new(name:, count: examples.size, examples: examples.uniq.first(EXAMPLES))
        }
      end

      # Whether a property is one this address book reads, asked of a
      # name as a line spells it.
      #: (String name) -> bool
      def self.known?(name)
        KNOWN.include?(name.upcase)
      end

      # Whether a property is one to drop without remark (NOISE).
      #: (String name) -> bool
      def self.noise?(name)
        NOISE.include?(name.upcase)
      end

      # The dropped lines a reader is meant to look at: everything a
      # card is losing but the noise. It is what the review list
      # counts on a row, and so what says whether the pair of cards
      # behind that row is worth opening at all — a contact losing
      # nothing but its exporter's name is a contact to leave shut.
      #: (Array[VCard::Parser::Line] dropped) -> Array[VCard::Parser::Line]
      def self.losses(dropped)
        dropped.reject { |line|
          property = line.property
          !property.nil? && (noise?(property.name) || property.name.casecmp?(CATEGORIES))
        }
      end

      # The tags a card carries, as the names of the groups they come
      # in as: every CATEGORIES line's comma-separated values, unescaped
      # (RFC 2426 section 2.4.2), blank ones and repeats left out.
      #: (VCard card) -> Array[String]
      def self.categories(card)
        card.properties.select { it.name.casecmp?(CATEGORIES) }.flat_map { |property|
          property.value.split(VCard::VALUE_SEPARATOR).map { VCard.unescape(it).strip }
        }.reject(&:empty?).uniq
      end

      # One card as this book will hold it, beside what that costs.
      # The kept lines are the bytes that arrived, in the order they
      # arrived, so a card comes in as the card it was; the dropped
      # ones are what no screen here would ever show, which is what
      # the review screen strikes through.
      #
      # A line that would not read is kept (the plan's "What comes
      # in").
      #: (VCard card) -> Reading
      def self.read(card)
        lines = card.lines
        orphaned = orphaned_groups(lines)
        kept, dropped = lines.partition { |line|
          property = line.property
          property.nil? || (known?(property.name) && !orphaned.include?(property.group&.downcase))
        }
        Reading.new(card: VCard.of(kept), dropped:)
      end

      # The group prefixes (`item1.`) with nothing left in them but a
      # label. Apple hangs a label off the line it names rather than
      # inside it, so bringing in `item3.X-ABLabel:_$!<Spouse>!$_`
      # without its `item3.X-ABRELATEDNAMES` would leave a name for a
      # line that is not there. A grouped property this book reads —
      # `item1.ADR`, say — anchors its own group, because it is coming
      # in, and so does a line that will not read, which comes in
      # whatever it is (#read): its group is read off its bytes, there
      # being no property to read it from.
      #: (Array[VCard::Parser::Line] lines) -> Array[String]
      def self.orphaned_groups(lines)
        anchored = {} #: Hash[String, bool]
        lines.each do |line|
          property = line.property
          group = property ? property.group : VCard::Parser.unfold(line.verbatim)[/\A([A-Za-z0-9-]+)\./, 1]
          next if group.nil?

          # A label is in its group without anchoring it, so a group
          # holding nothing else is one with nothing but a label in it.
          anchors = property.nil? || (!property.name.casecmp?(LABEL) && known?(property.name))
          # Without case, as a property name compares and as
          # EditedContact#label_of and Merge pair a label with its
          # line: `ITEM1.X-ABLabel` names `item1.TEL`'s group.
          key = group.downcase
          anchored[key] = anchored.fetch(key, false) || anchors
        end
        anchored.reject { |_group, kept| kept }.keys
      end

      # A line unfolded, without its terminator, cut short of a
      # payload nobody wants to read — the one rendering of a line
      # this import shows (Admin::ImportOriginal), and Unknown's
      # examples.
      #: (VCard::Parser::Line line) -> String
      def self.summary(line)
        text = VCard::Parser.unfold(line.verbatim).chomp
        return text if text.length <= EXAMPLE_LENGTH

        "#{text[0, EXAMPLE_LENGTH]}… (#{text.length} characters)"
      end

      private_class_method :orphaned_groups
    end
  end
end
