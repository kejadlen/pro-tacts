require "date"
require "time"

require "pro_tacts/birthday"

module ProTacts
  module Admin
    # Small display helpers shared by the admin views. Presentation, not
    # structure: these read a Contact but decide only how it looks.
    module Format
      # A contact's initials. N's given and family names (RFC 2426
      # section 3.1.2) are structured data and the real answer to "what
      # are this contact's initials" — falling back, when the card
      # carries no N (an organization's own entry, say, with a name but
      # no person to split in two), to one first letter of FN rather
      # than a guess at where a first/last split would fall in free
      # text, and of the id when the card carries no name at all.
      #: (Contact contact) -> String
      def self.initials(contact)
        family, given = contact.name_components || []
        letters = [given, family].filter_map { it[0] if it }
        return letters.join.upcase unless letters.empty?

        (contact.name || contact.id).to_s.strip[0].to_s.upcase
      end

      # The birthday a card carries, for display: the model's date when
      # the model holds one, the reduced no-year spelling rendered as its
      # day, and the raw property for anything else — a BDAY in a spelling
      # the model doesn't recompose is kept in the card verbatim on write,
      # so it's shown as stored.
      #: (Contact contact) -> String?
      def self.birthday(contact)
        birthday = contact.birthday
        return reduced_no_year(contact) || raw_birthday(contact) if birthday.nil?

        if birthday.year
          Date.new(birthday.year, birthday.month, birthday.day).strftime("%B %-d, %Y")
        else
          Date.new(2000, birthday.month, birthday.day).strftime("%B %-d")
        end
      rescue ArgumentError
        # A birthday whose stored value is well-shaped but
        # calendar-nonsense: the model checks component ranges, not the
        # calendar, so February 30 parses and only Date.new refuses it.
        # The ordinary anticipated case, shown as stored rather than
        # raised.
        raw_birthday(contact)
      end

      #: (Contact contact) -> String?
      def self.raw_birthday(contact)
        contact.properties.find { it.name.casecmp?("BDAY") }&.value
      end

      # A no-year BDAY in the reduced spelling (Birthday::REDUCED_DATE):
      # macOS reads it on a card it did not write, but the model
      # recomposes only the two forms it serves, so the line stays in the
      # card verbatim and this renders it as the day it names. Bare only,
      # like the model's own reads — a grouped or parametered BDAY's
      # pairing belongs to the card, not this row.
      #: (Contact contact) -> String?
      def self.reduced_no_year(contact)
        property = contact.properties.find { it.name.casecmp?("BDAY") }
        return nil if property.nil? || property.group || !property.parameters.empty?

        match = property.value.match(Birthday::REDUCED_DATE)
        return nil if match.nil?

        # The pattern matches without capturing (it is a predicate
        # elsewhere); the matched string carries the components — two
        # digits of month and two of day, an optional dash between.
        digits = match[0].delete_prefix("--").delete("-")
        Date.new(2000, digits[0, 2].to_i, digits[2, 2].to_i).strftime("%B %-d")
      rescue ArgumentError
        # Calendar-nonsense in this spelling too (February 30): shown as
        # stored, like the modeled branch above.
        nil
      end

      # A card's updated_at, UTC ISO 8601 to the millisecond (see
      # Store), rendered the way "recently updated" wants it: coarse and
      # relative, not a timestamp to read precisely.
      #: (String iso8601) -> String
      def self.time_ago(iso8601)
        seconds = (Time.now.utc - Time.iso8601(iso8601)).round
        return "just now" if seconds < 60

        minutes = seconds / 60
        return "#{minutes}m ago" if minutes < 60

        hours = (minutes / 60.0).round
        return "#{hours}h ago" if hours < 24

        days = (hours / 24.0).round
        return "#{days}d ago" if days < 30

        "#{(days / 30.0).round}mo ago"
      end

      # time_ago's other half: how far ahead a known day is, rendered
      # with the same coarseness. A birthday list spans weeks, so days
      # give way to weeks after a fortnight and to months after a
      # quarter.
      #: (Date date) -> String
      def self.time_until(date)
        days = (date - Date.today).to_i
        return "today" if days.zero?
        return "tomorrow" if days == 1
        return "in #{days}d" if days < 14
        return "in #{(days / 7.0).round}w" if days < 90

        "in #{(days / 30.0).round}mo"
      end
    end
  end
end
