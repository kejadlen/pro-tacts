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

      # The birthday a card carries, for display: the model's when the
      # card carries one it recomposes, otherwise any well-shaped
      # stored spelling parsed by Birthday.from_value — bare properties
      # only, like the model's own reads — and the raw value for
      # everything else, shown as stored. The prose itself is
      # Birthday#to_s, every shape's one rendering.
      #: (Contact contact) -> String?
      def self.birthday(contact)
        property = contact.properties.find { it.name.casecmp?("BDAY") }
        return nil if property.nil?

        birthday = contact.birthday
        if birthday.nil? && property.group.nil? && property.parameters.empty?
          birthday = Birthday.from_value(property.value)
        end
        birthday&.to_s || property.value
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
