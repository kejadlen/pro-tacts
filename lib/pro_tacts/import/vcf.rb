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
    # choosing what their own book is made of. So the reading this
    # module owes is the split into cards and the question the importer
    # is asked: of the properties no screen here shows, which are worth
    # saving under the note on the way past?
    module Vcf
      # A file that is not a set of vCards.
      class Invalid < StandardError; end

      # The properties this address book reads, and so the properties
      # an import brings in. The envelope (BEGIN, END, VERSION, UID),
      # the fields a screen shows (Contact's own readers: N, FN,
      # NICKNAME, TEL, EMAIL, ADR, NOTE, PHOTO, and the X-ABLabel that
      # names a row), and BDAY, which the store takes into the model on
      # the way in
      # (docs/plans/2026-09-11-every-birthday-in-the-model.md).
      #
      # Everything else is unknown, which here means "no screen will
      # show it". The list is the reader's, not the writer's: adding a
      # screen for a property is what brings it in, and until then
      # importing one would only pad the cards with what nobody can
      # read.
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

      # What the importer can ask for an unknown property. Dropping is
      # the default, and what happens to anything not spoken for: a
      # line no screen here shows is a line this book has no use for,
      # and carrying it in would leave every card padded with the
      # source's bookkeeping. The note is the way out for a value worth
      # reading even with no field to read it in — a spouse's name is
      # worth more under the note than nowhere.
      DROP = "drop" #: String
      NOTE = "note" #: String
      CHOICES = [DROP, NOTE].freeze #: Array[String]

      # One property the file carries that KNOWN does not name, across
      # every card in it: how many lines wear it, and a few of their
      # real values, so a choice is made looking at the source's own
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
            next if known?(name)

            (seen[name] ||= []) << example(line)
          end
        end
        seen.sort.map { |name, examples|
          Unknown.new(name:, count: examples.size, examples: examples.uniq.first(EXAMPLES))
        }
      end

      # Whether a property is one this address book reads, asked of a
      # name as a line spells it — the one question both the survey
      # and the landing ask (Land#decide).
      #: (String name) -> bool
      def self.known?(name)
        KNOWN.include?(name.upcase)
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
