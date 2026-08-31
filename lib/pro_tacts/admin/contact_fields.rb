require "date"

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

      # RFC 2426 section 3.1.5 defines BDAY as a date or a date-time; the
      # reduced-precision "--MM-DD" form (ISO 8601, not RFC 2426 itself)
      # is how a year gets omitted. Matched explicitly rather than
      # handed to Date.iso8601, which parses "--12-10" by silently
      # filling in the current year — exactly the wrong answer for a
      # birthday that deliberately has none. See the open question on
      # year omission in docs/plans/2026-08-24-vcard-storage-and-groups.md.
      FULL_DATE = /\A(\d{4})-(\d{2})-(\d{2})/
      NO_YEAR_DATE = /\A--(\d{2})-(\d{2})/

      attr_reader :name, :phones, :emails, :addresses, :birthday, :notes

      #: (Contact contact) -> ContactFields
      def self.from(contact)
        properties = VCard::Parser.parse(contact.vcard)
        new(properties)
      rescue VCard::ParseError
        new([])
      end

      #: (Array[VCard::Property] properties) -> void
      def initialize(properties)
        by_name = properties.group_by { it.name.upcase }
        @name = by_name.fetch("FN", []).first&.value
        @phones = by_name.fetch("TEL", []).map { |p| Phone.new(value: VCard.unescape(p.value), type: type_of(p)) }
        @emails = by_name.fetch("EMAIL", []).map { |p| Email.new(value: VCard.unescape(p.value), type: type_of(p)) }
        @addresses = by_name.fetch("ADR", []).map { |p| address_from(p) }
        @birthday = format_birthday(by_name.fetch("BDAY", []).first&.value)
        note = by_name.fetch("NOTE", []).first&.value
        @notes = note && VCard.unescape(note)
      end

      private

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

      # A value this cannot recognize is shown as stored rather than
      # dropped or guessed at.
      #: (String? value) -> String?
      def format_birthday(value)
        return nil if value.nil? || value.empty?

        if (m = value.match(FULL_DATE))
          Date.new(m[1].to_i, m[2].to_i, m[3].to_i).strftime("%B %-d, %Y")
        elsif (m = value.match(NO_YEAR_DATE))
          Date.new(2000, m[1].to_i, m[2].to_i).strftime("%B %-d")
        else
          value
        end
      rescue ArgumentError
        value
      end
    end
  end
end
