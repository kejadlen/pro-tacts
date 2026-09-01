require "date"
require "time"

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
        letters = [given, family].filter_map { it[0] unless it.to_s.empty? }
        return letters.join.upcase unless letters.empty?

        (contact.name || contact.id).to_s.strip[0].to_s.upcase
      end

      # The birthday a card carries, for display: the model's date when
      # the model holds one, the raw property when it does not — a BDAY
      # in a spelling the model doesn't recompose is kept in the card
      # verbatim on write, so it's shown as stored.
      #: (Contact contact) -> String?
      def self.birthday(contact)
        birthday = contact.birthday
        return raw_birthday(contact) if birthday.nil?

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
    end
  end
end
