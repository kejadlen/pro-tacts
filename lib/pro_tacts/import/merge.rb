require "pro_tacts/birthday"
require "pro_tacts/contact"
require "pro_tacts/import/match"
require "pro_tacts/import/vcf"
require "pro_tacts/vcard"

module ProTacts
  module Import
    # An arriving card folded into a contact the book already has: what
    # the walk's editor renders when its toggle names that contact
    # rather than a new one (docs/plans/2026-09-23-merging-on-import.md).
    #
    # The contact's own card is the base and keeps every byte it has;
    # the arriving card adds only what the contact does not hold yet. A
    # phone, an email or an address comes in beside the ones the
    # contact has, unless it is one of them. A name, a nickname, a
    # note, a photo, an organization or a birthday — what a contact
    # holds one of — comes in only where the contact has none, and
    # where the two differ the book's own stands. What that leaves behind is #left, struck on
    # the card as exported the way every other line not coming in is
    # (Admin::ImportOriginal), so nothing is lost without having been
    # shown first.
    #
    # Nothing here writes. The editor renders over #contact, and the
    # save derives it again to check the etag the form carried, so a
    # contact that changed in between refuses the save the way any
    # stale editor does.
    class Merge
      # @rbs @into: Contact
      # @rbs @labels: Hash[String, Array[VCard::Parser::Line]]
      # @rbs @groups: Hash[String, String]
      # @rbs @named_groups: Array[String]
      # @rbs @arriving_notes: Array[String]
      # @rbs @contact: Contact
      # @rbs @left: Array[VCard::Parser::Line]

      # What a contact holds many of: an arriving one joins the
      # contact's unless the contact already has its value.
      MANY = %w[TEL EMAIL ADR].freeze #: Array[String]

      # What a contact holds one of: an arriving one fills a gap, and
      # is left behind where the contact has its own.
      ONE = %w[N FN NICKNAME NOTE PHOTO ORG X-ABSHOWAS].freeze #: Array[String]

      # The envelope, which the contact has its own of — its UID above
      # all, the arriving one naming a record in some other book
      # (Import::Write#identified's reason). Neither kept nor a loss.
      ENVELOPE = %w[BEGIN END VERSION UID].freeze #: Array[String]

      # The contact the card is folded into, and the card: the staged
      # one, already pared to what this book reads (Vcf.read).
      #: (Contact into, VCard card) -> void
      def initialize(into, card)
        @into = into
        @labels = labels(card)
        @groups = {} #: Hash[String, String]
        @named_groups = into.stored.properties.filter_map { it.group&.downcase }
        taken = [] #: Array[String]
        arriving_notes = [] #: Array[String]
        left = [] #: Array[VCard::Parser::Line]
        birthday = into.birthday
        card.lines.each do |line|
          property = line.property
          # A line that would not read rides along, Vcf.read's rule:
          # there is nothing about it anyone could have decided.
          if property.nil?
            taken << line.verbatim unless line.verbatim.strip.empty?
            next
          end

          name = property.name.upcase
          if MANY.include?(name)
            taken.concat(moved(line, property)) unless held?(property)
          elsif ONE.include?(name)
            own = into.stored.property(name)
            if own.nil?
              # A contact holds one note, so several arriving join into
              # the one they fill (docs/plans/2026-09-25-one-note-per-
              # contact.md); the joined line is written below the walk.
              if name == "NOTE"
                arriving_notes << property.text
              else
                taken.concat(moved(line, property))
              end
            elsif own.value != property.value
              left << line
            end
          elsif name == "BDAY"
            # Into the model where the contact has no birthday at all,
            # the split Store#put makes on the way in; a spelling the
            # model does not read stays a line, that method's own rule.
            arriving = Birthday.from_property(property)
            if birthday.nil? && into.stored.lines.none? { it.names?("BDAY") }
              if arriving
                birthday = arriving
              else
                taken.concat(moved(line, property))
              end
            elsif arriving != birthday
              left << line
            end
          elsif !ENVELOPE.include?(name) && name != Vcf::LABEL
            left << line
          end
        end
        @left = left
        # The arriving notes' one line, at the walk's end: whatever
        # order they arrived in, the join is the value the book keeps
        # and the one-note invariant asks for.
        unless arriving_notes.empty?
          taken << "NOTE:#{VCard.escape(arriving_notes.join("\n\n"))}\r\n"
        end
        @contact = into.with(stored: into.stored.insert(taken), birthday:)
      end

      # The contact as it would be saved, which the editor renders.
      attr_reader :contact

      # The arriving lines the contact's own stood in for.
      attr_reader :left

      private

      # Whether the contact already has this value, as it serves it:
      # an address a group lends it is an address it has.
      #: (VCard::Parser::Property property) -> bool
      def held?(property)
        key = key(property)
        @into.properties.any? { it.name.casecmp?(property.name) && key(it) == key }
      end

      # A value as two spellings of it compare: a number by its digits
      # (Match.phone), an address by its components, the rest without
      # case or the space around it.
      #: (VCard::Parser::Property property) -> String
      def key(property)
        case property.name.upcase
        when "TEL" then Match.phone(property.text)
        when "ADR" then property.components.map { it.strip.downcase }.join(";")
        else property.text.strip.downcase
        end
      end

      # A line's bytes as they join the contact's card, with the label
      # hung off it. Apple numbers a card's `item1.` groups per card,
      # so an arriving one can name a group the contact's card already
      # has; it is renumbered past all of them, and its label
      # (Vcf::LABEL) moves with it — Vcf.read's rule that a label goes
      # wherever the line it names goes.
      #: (VCard::Parser::Line line, VCard::Parser::Property property) -> Array[String]
      def moved(line, property)
        group = property.group
        return [line.verbatim] if group.nil?

        fresh = @groups[group.downcase]
        lines = fresh ? [line] : [line, *@labels.fetch(group.downcase, [])]
        fresh ||= (@groups[group.downcase] = fresh_group)
        lines.map { it.verbatim.sub(/\A#{Regexp.escape(group)}\./i, "#{fresh}.") }
      end

      #: () -> String
      def fresh_group
        number = 1
        number += 1 while @named_groups.include?("item#{number}")
        name = "item#{number}"
        @named_groups << name
        name
      end

      # The arriving card's labels, by the group each names.
      #: (VCard card) -> Hash[String, Array[VCard::Parser::Line]]
      def labels(card)
        labels = {} #: Hash[String, Array[VCard::Parser::Line]]
        card.lines.each do |line|
          property = line.property
          next if property.nil? || !property.name.casecmp?(Vcf::LABEL)

          group = property.group
          (labels[group.downcase] ||= []) << line if group
        end
        labels
      end
    end
  end
end
