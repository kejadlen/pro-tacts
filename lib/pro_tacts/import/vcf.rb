require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  module Import
    # An uploaded .vcf, read as the cards it holds and as what this
    # server does not recognise in them
    # (docs/plans/2026-09-21-import-a-vcf.md).
    #
    # Nothing here rebuilds a card out of fields. A contact arrives as a
    # vCard and is stored as one — RFC 6352 section 6.3.2.2 requires a
    # server to keep what it does not understand, and this one does
    # (vcard.rb) — so the reading this module owes is the split into
    # cards and the question the importer is asked: of the properties
    # no screen here shows, which are worth keeping?
    module Vcf
      # A file that is not a set of vCards.
      class Invalid < StandardError; end

      # The properties this address book reads. The envelope (BEGIN,
      # END, VERSION, UID), the fields a screen shows (Contact's own
      # readers: N, FN, NICKNAME, TEL, EMAIL, ADR, NOTE, PHOTO, and the
      # X-ABLabel that names a row), and BDAY, which the store takes
      # into the model on the way in
      # (docs/plans/2026-09-11-every-birthday-in-the-model.md).
      #
      # Everything else is unknown, which here means "nothing here will
      # show it", not "nothing here can hold it": a kept line is served
      # back byte for byte like any other. That is why the list is the
      # reader's and not the writer's.
      # Apple's own name for a row, carried on a line of its own beside
      # the one it names (`item1.X-ABLabel:_$!<Spouse>!$_`). Known, and
      # named apart from the rest because a decision about the line it
      # annotates is a decision about it too: a label whose line is
      # gone names nothing (Land#decide).
      LABEL = "X-ABLABEL" #: String

      KNOWN = [
        *%w[BEGIN END VERSION UID N FN NICKNAME BDAY TEL EMAIL ADR NOTE PHOTO],
        LABEL,
      ].freeze #: Array[String]

      # What the importer can ask for an unknown property. Keeping is
      # the default because it loses nothing: the line is stored as it
      # arrived and served back untouched, invisible to these screens
      # rather than gone. Dropping is for what the source keeps and
      # this book has no use for. The note is for a value worth reading
      # even with no field to read it in — a spouse's name is worth
      # more under the note than nowhere.
      KEEP = "keep" #: String
      DROP = "drop" #: String
      NOTE = "note" #: String
      CHOICES = [KEEP, DROP, NOTE].freeze #: Array[String]

      # One property the file carries that KNOWN does not name, across
      # every card in it: how many lines wear it, and a few of their
      # real values, so a choice is made looking at this book's own
      # data rather than at a property name. Signed in
      # sig/pro_tacts/import.rbs, being a Data class.
      # @rbs skip
      Unknown = Data.define(:name, :count, :examples)

      EXAMPLES = 3 #: Integer

      # Long enough for a line's parameters, short of a photo's payload.
      EXAMPLE_LENGTH = 120 #: Integer

      # The cards a file holds, in the order it wrote them, each as the
      # bytes it arrived in. A card is what lies from BEGIN to END, and
      # the lines between cards are blank or the file is not a set of
      # vCards — refused whole rather than partly imported, `execute`'s
      # own rule that a source which will not read lands nothing.
      #: (String bytes) -> Array[VCard]
      def self.cards(bytes)
        cards = [] #: Array[VCard]
        open = nil #: Array[VCard::Parser::Line]?
        VCard::Parser.lines(bytes).each do |line|
          name = line.property&.name
          if open.nil?
            next if line.verbatim.strip.empty?

            raise Invalid, "a line outside a card: #{example(line)}" unless name&.casecmp?("BEGIN")

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
      # parser hands one back without a property, the card is served
      # from its bytes regardless, and there is no field it could be
      # dropped out of (vcard/parser.rb's own posture).
      #: (Array[VCard] cards) -> Array[Unknown]
      def self.unknown(cards)
        seen = {} #: Hash[String, Array[String]]
        cards.each do |card|
          card.lines.each do |line|
            property = line.property
            next if property.nil?

            name = property.name.upcase
            next if KNOWN.include?(name)

            (seen[name] ||= []) << example(line)
          end
        end
        seen.sort.map { |name, examples|
          Unknown.new(name:, count: examples.size, examples: examples.uniq.first(EXAMPLES))
        }
      end

      # A line unfolded, without its terminator, cut short of a
      # payload nobody wants to read.
      #: (VCard::Parser::Line line) -> String
      def self.example(line)
        text = VCard::Parser.unfold(line.verbatim).chomp
        return text if text.length <= EXAMPLE_LENGTH

        "#{text[0, EXAMPLE_LENGTH]}… (#{text.length} characters)"
      end

      private_class_method :example
    end
  end
end
