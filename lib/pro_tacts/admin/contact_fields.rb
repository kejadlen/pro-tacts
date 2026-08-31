require "date"

require "pro_tacts/admin/format"
require "pro_tacts/birthday"
require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  module Admin
    # The read-only fields an admin screen shows for a contact, parsed
    # fresh from its stored vCard on every read. Deliberately shallow,
    # like VCard::Parser itself: a card can carry properties this has no
    # field for, and CardDAV still serves every one of them — this is
    # only what one screen knows how to display.
    class ContactFields
      Phone = Data.define(:value, :type)
      Email = Data.define(:value, :type)
      Address = Data.define(:lines, :type)

      attr_reader :name, :initials, :phones, :emails, :addresses, :birthday, :notes

      # Lets VCard::ParseError raise rather than showing an empty card:
      # a stored card that fails to parse here is not the ordinary case
      # #format_birthday's rescue handles (a well-shaped but nonsense
      # value that round-trips on purpose) — every PUT already checks
      # VCard.card? before the store accepts a card, so one reaching
      # this unparseable is a bug or a corrupt row, and Sentry (already
      # wired into every request, see ProTacts::Web) is where that
      # should surface, not a silently blank screen.
      #: (Contact contact) -> ContactFields
      def self.from(contact)
        properties = VCard::Parser.parse(contact.vcard)
        new(properties)
      end

      #: (Array[VCard::Property] properties) -> void
      def initialize(properties)
        by_name = properties.group_by { it.name.upcase }
        @name = by_name.fetch("FN", []).first&.value
        @initials = initials_from(by_name.fetch("N", []).first) || (@name && Format.initials(@name))
        @phones = by_name.fetch("TEL", []).map { |p| Phone.new(value: VCard.unescape(p.value), type: type_of(p)) }
        @emails = by_name.fetch("EMAIL", []).map { |p| Email.new(value: VCard.unescape(p.value), type: type_of(p)) }
        @addresses = by_name.fetch("ADR", []).map { |p| address_from(p) }
        @birthday = format_birthday(by_name.fetch("BDAY", []).first)
        note = by_name.fetch("NOTE", []).first&.value
        @notes = note && VCard.unescape(note)
      end

      private

      # RFC 2426 section 3.1.2: N is Family;Given;Additional;Prefixes;
      # Suffixes. A given and family name are structured data — reading
      # them is the real answer to "what are this contact's initials,"
      # rather than guessing at where a first/last split falls in the
      # free-text FN. A card with no N at all (an organization's own
      # address-book entry, say, with a name but no person to split in
      # two) falls back to Format.initials' single first letter.
      #: (VCard::Property? property) -> String?
      def initials_from(property)
        return nil if property.nil?

        family, given = VCard.split_components(property.value)
        letters = [given, family].filter_map { |part| part[0] unless part.to_s.empty? }
        letters.empty? ? nil : letters.join.upcase
      end

      # RFC 2426 section 3.3.1: TYPE can repeat (TYPE=work;TYPE=voice) or
      # comma-list (TYPE=work,voice) — either arrives here as one
      # parameter per value, so the first is the one this shows.
      #: (VCard::Property property) -> String?
      def type_of(property)
        property.parameters.find { |name, _| name.casecmp?("TYPE") }&.last&.downcase
      end

      # ADR's components, RFC 2426 section 3.2.1: post office box,
      # extended address, street, locality, region, postal code,
      # country. Displayed as two lines — street, then everything after
      # it — the same shape the design's own address rows settled on.
      #: (VCard::Property property) -> Address
      def address_from(property)
        _po_box, extended, street, city, region, postal_code, country = VCard.split_components(property.value)
        lines = [
          [extended, street].reject { |s| s.nil? || s.empty? }.join(" "),
          [city, region, postal_code].reject { |s| s.nil? || s.empty? }.join(", "),
          country,
        ].reject { |s| s.nil? || s.empty? }
        Address.new(lines:, type: type_of(property))
      end

      # Reuses ProTacts::Birthday, which knows the two BDAY spellings a
      # served card actually carries (see lib/pro_tacts/birthday.rb): a
      # plain full date, and Apple's 1604-sentinel no-year form. A BDAY
      # in any other shape is one the app's model doesn't recompose —
      # kept in the card verbatim on write — so it's shown as stored.
      #: (VCard::Property? property) -> String?
      def format_birthday(property)
        return nil if property.nil?

        birthday = Birthday.from_property(property)
        return property.value if birthday.nil?

        if birthday.year
          Date.new(birthday.year, birthday.month, birthday.day).strftime("%B %-d, %Y")
        else
          Date.new(2000, birthday.month, birthday.day).strftime("%B %-d")
        end
      rescue ArgumentError
        property.value
      end
    end
  end
end
