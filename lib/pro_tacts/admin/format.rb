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

      # A contact's birthday, for display: the model's — composed into
      # the served card when a client can carry it, held alone when no
      # form serves it (the editor can save a shape nothing renders,
      # and the details page still shows what the record holds) — then
      # any well-shaped stored spelling parsed by Birthday.from_value,
      # bare properties only, like the model's own reads, and the raw
      # value for everything else, shown as stored. The prose itself is
      # Birthday#to_s, every shape's one rendering.
      #: (Contact contact) -> String?
      def self.birthday(contact)
        property = contact.properties.find { it.name.casecmp?("BDAY") }
        return contact.birthday&.to_s if property.nil?

        birthday = contact.birthday
        if birthday.nil? && property.group.nil? && property.parameters.empty?
          birthday = Birthday.from_value(property.value)
        end
        birthday&.to_s || property.value
      end

      # ADR's components as display lines — street, then everything
      # after it — the shape the design's own address rows settled on,
      # and one shape for a contact's card and a group's alike.
      # Presentation: the components themselves are Contact's.
      #: (Contact::Address address) -> Array[String]
      def self.address_lines(address)
        [
          [address.extended, address.street].compact.join(" "),
          [address.locality, address.region, address.postal_code].compact.join(", "),
          address.country,
        ].compact.reject { it.empty? }
      end

      # A row's types as its key, or the kind of value when it has
      # none, so no row renders unlabeled in the grid.
      #: (Array[String] types, String kind) -> String
      def self.type_label(types, kind)
        types.empty? ? kind : types.join(", ")
      end

      # How much of an etag's hash is shown before it is cut. Twelve
      # hex digits is git's own longest short-hash, and this address
      # book will never hold enough cards for two to collide in a
      # reader's eye.
      ETAG_DIGITS = 12 #: Integer

      # An etag's hash, without the quotes an entity-tag is spelled
      # with (Contact.etag_for): those are the wire's punctuation, and
      # a screen showing a card's history is not the wire. Anything
      # not shaped like an entity-tag comes back untouched — there is
      # no second spelling to guess at.
      #: (String etag) -> String
      def self.etag_digest(etag)
        etag[/\A"(.*)"\z/, 1] || etag
      end

      # The hash cut down for display. Whole, it is 64 digits, which
      # wraps over two lines in a record's value column and reads as a
      # wall either way; the view hands the whole of it to the title
      # of the <abbr> this sits in, so the cut is a display and not a
      # loss.
      #: (String etag) -> String
      def self.short_etag(etag)
        digest = etag_digest(etag)
        return digest if digest.length <= ETAG_DIGITS

        "#{digest[0, ETAG_DIGITS]}…"
      end

      # The other way to render one of those stamps: as itself, minus
      # the milliseconds. What the change log records happened at a
      # moment someone may need to line up against a client's own logs,
      # so this one stays absolute where #time_ago goes coarse — and the
      # fraction is the clock's precision rather than the change's.
      # String surgery rather than a parse and a reformat, because the
      # column's spelling is fixed by the expression that writes it (see
      # db/migrations/001_create_contacts_schema.rb).
      #: (String iso8601) -> String
      def self.stamp(iso8601)
        iso8601.sub(/\.\d+Z\z/, "Z")
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
