require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  module Import
    # An uploaded .vcf, read as the cards it holds and as what this
    # server does not recognise in them
    # (docs/plans/2026-09-21-import-a-vcf.md).
    #
    # Nothing here rebuilds a card out of fields: a contact arrives as a
    # vCard and is stored as one, and every line this address book reads
    # travels through untouched. What an import does not do is carry in
    # what nothing here will ever show. RFC 6352 section 6.3.2.2 binds
    # this server to keep what a client submits and does not understand,
    # and it does (vcard.rb); an import is the other direction, a person
    # choosing what their own book is made of.
    #
    # So this module owes two readings. The split into cards, and then
    # per card the split #read makes: what is coming in, and what is
    # being left behind. A contact's own screen shows both at once —
    # the card as it was exported with the doomed lines struck, beside
    # the card that is coming in, open in the editor — so nothing is
    # lost without having been shown first (Admin::ImportOriginal),
    # and the count of what one is losing is the mark its row in the
    # walk wears (Admin::ImportSidebar).
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
      # an import brings in. The envelope (BEGIN, END, VERSION, UID),
      # the fields a screen shows (Contact's own readers: N, FN,
      # NICKNAME, TEL, EMAIL, ADR, NOTE, PHOTO, and the X-ABLabel that
      # names a row), and BDAY, which the store takes into the model on
      # the way in
      # (docs/plans/2026-09-11-every-birthday-in-the-model.md). ORG and
      # Apple's X-ABShowAs are a company card
      # (docs/plans/2026-09-24-company-cards.md), whose editor reads
      # its name out of either and which the contacts page searches.
      #
      # Everything else is unknown, which here means "no screen will
      # show it". The list is the reader's, not the writer's: adding a
      # screen for a property is what brings it in, and until then
      # importing one would only pad the cards with what nobody can
      # read.
      KNOWN = [
        *%w[BEGIN END VERSION UID N FN NICKNAME BDAY TEL EMAIL ADR NOTE PHOTO ORG X-ABSHOWAS],
        LABEL,
      ].freeze #: Array[String]

      # Unknown, and not worth saying so. PRODID names the program
      # that wrote the file rather than anything about the person, and
      # every export carries one; SOURCE and REV, which Monica writes
      # on every card, are where the card came from and when it last
      # changed there — the export's facts again. Counted as a loss it would put a
      # line in every file's summary and a mark on every contact's
      # row, for a fact nobody is going to copy into a card. What goes
      # quiet is the asking, not the dropping — the line still does
      # not come in, and the card as exported still shows it struck
      # (Admin::ImportOriginal), because that card is the file's own
      # bytes and a line shown plain there would be a line claiming to
      # arrive.
      NOISE = %w[PRODID SOURCE REV].freeze #: Array[String]

      # Tags (RFC 2426 section 3.6.1), which come in as groups rather
      # than as a line: the walk ticks a group of each name beside the
      # card (Web#import_picker), so what the line said arrives, and
      # the line itself, struck on the card as exported, is not a loss
      # to count.
      CATEGORIES = "CATEGORIES" #: String

      # What an import makes of one card: the card as it will come in,
      # and the lines it leaves behind. Both, because the review
      # screen shows them side by side — the original with its doomed
      # lines struck, and the card that is actually coming in, open in
      # the editor (Admin::ImportOriginal). Signed in
      # sig/pro_tacts/import.rbs, being a Data class.
      # @rbs skip
      Reading = Data.define(:card, :dropped)

      # One property the file carries that KNOWN does not name, across
      # every card in it: how many lines wear it, and a few of their
      # real values. The review screen's summary of what the whole
      # file is losing, read before working down the contacts one by
      # one. Signed in sig/pro_tacts/import.rbs, being a Data class.
      # @rbs skip
      Unknown = Data.define(:name, :count, :examples)

      EXAMPLES = 3 #: Integer

      # Long enough for a line's parameters, short of a photo's payload.
      EXAMPLE_LENGTH = 120 #: Integer

      # The cards a file holds, in the order it wrote them, each as the
      # bytes it arrived in. A card is what lies from BEGIN to END, and
      # the lines between cards are blank or the file is not a set of
      # vCards — refused whole rather than partly imported: a source
      # that will not read brings in nothing.
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
            open << line
            next unless name&.casecmp?("END")

            cards << VCard.new(open.map(&:verbatim).join)
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
      # name rather than by the spelling the line wore: the three
      # choices read the same whatever parameters a line carries, so
      # `X-SOCIALPROFILE;type=twitter` is not a second decision from
      # `X-SOCIALPROFILE`. Ordered by name, a list to work down.
      #
      # An unreadable line is not among them and asks nothing: the
      # parser hands one back without a property, so there is no
      # property name to decide about and nothing to say about it on
      # a screen. It travels with the card rather than being thrown
      # away unnamed (vcard/parser.rb's own posture).
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
      # name as a line spells it — the one question the survey, the
      # review screen and the write all ask.
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
          property.value.split(/(?<!\\),/).map { VCard.unescape(it).strip }
        }.reject(&:empty?).uniq
      end

      # One card as this book will hold it, beside what that costs.
      # The kept lines are the bytes that arrived, in the order they
      # arrived, so a card comes in as the card it was; the dropped
      # ones are what no screen here would ever show, which is what
      # the review screen strikes through.
      #
      # A line that would not read is kept. The parser hands one back
      # without a property name, so there is nothing to have shown on
      # a screen and nothing anyone could have decided about it, and
      # throwing it away unnamed is worse than letting it ride in the
      # card's bytes (vcard/parser.rb's own posture).
      #: (VCard card) -> Reading
      def self.read(card)
        lines = card.lines
        orphaned = orphaned_groups(lines)
        kept, dropped = lines.partition { |line|
          property = line.property
          property.nil? || (known?(property.name) && !orphaned.include?(property.group))
        }
        Reading.new(card: VCard.new(kept.map(&:verbatim).join), dropped:)
      end

      # The group prefixes (`item1.`) with nothing left in them but a
      # label. Apple hangs a label off the line it names rather than
      # inside it, so bringing in `item3.X-ABLabel:_$!<Spouse>!$_`
      # without its `item3.X-ABRELATEDNAMES` would leave a name for a
      # line that is not there. A grouped property this book reads —
      # `item1.ADR`, say — anchors its own group, because it is coming
      # in.
      #: (Array[VCard::Parser::Line] lines) -> Array[String]
      def self.orphaned_groups(lines)
        anchored = {} #: Hash[String, bool]
        lines.each do |line|
          property = line.property
          next if property.nil?

          group = property.group
          next if group.nil? || property.name.casecmp?(LABEL)

          anchored[group] = anchored.fetch(group, false) || known?(property.name)
        end
        anchored.reject { |_group, kept| kept }.keys
      end

      # A line unfolded, without its terminator, cut short of a
      # payload nobody wants to read — the one rendering of a line
      # this import shows, in the survey's examples and in the review
      # screen's reading of the original card
      # (Admin::ImportOriginal).
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
