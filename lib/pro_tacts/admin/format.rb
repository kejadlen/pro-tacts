require "time"

module ProTacts
  module Admin
    # Small display helpers shared by the admin views.
    module Format
      # The first letter of a name with nothing more structured to go
      # on — an id, or a display name with no N property behind it
      # (see ContactFields#initials_from). One letter rather than a
      # guess at where a first/last split would fall in free text.
      #: (String name) -> String
      def self.initials(name)
        name.to_s.strip[0].to_s.upcase
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
