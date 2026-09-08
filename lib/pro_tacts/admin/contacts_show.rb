require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/format"
require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # GET /contacts/:id — a contact's card, read-only. Follows
    # docs/DESIGN.md's alignment rule even before there is anything to
    # edit: every row's type sits in one column and its value in the
    # other, and an attribute with no data gets no row at all.
    #
    # The mockup this was built from leads each row with a Lucide icon
    # instead of a type label once there is more than one row of the
    # same kind; nothing here vendors an icon set yet, so every row
    # keeps its mono type label for now. Revisit once Gloss or this
    # project settles on how icons ship.
    class ContactsShow < Phlex::HTML
      # A value — a property's or a parameter's — at or under this many
      # octets renders whole. Anything longer is a wall of folded or
      # unbroken octets (an inline PHOTO payload, a memoji's binary
      # plist parameter, a novel-length NOTE) and renders as its count.
      ELIDE_ABOVE = 120 #: Integer
      private_constant :ELIDE_ABOVE

      #: (Contact contact) -> void
      def initialize(contact:)
        @contact = contact
        @birthday = Format.birthday(contact)
      end

      def view_template
        render Layout.new(title: @contact.name || @contact.id) do
          # The back-link line and the record card are one block, the
          # line its caption row: spaced like the dashboard's
          # section-head over its card (see .record in admin.css), not
          # like a block of the column's own. The raw vCard card below
          # stays a sibling at the column's rhythm.
          div(class: "record") do
            div(class: "record-nav") do
              a(href: "/", class: "type-label") { "‹ contacts" }
              a(href: "/contacts/#{@contact.id}/edit", class: "btn", data_size: "sm") { "edit" }
            end
            div(class: "card") do
              div(class: "card-body") do
                div(class: "detail-header") do
                  div do
                    h1(class: "type-h2", style: "margin: 0;") { @contact.name || @contact.id }
                    # The nickname rides under the name in the heading
                    # family — type-h3 to the name's h2 — so it reads as
                    # a name rather than a property value; muted, so the
                    # formal name stays the heading.
                    if @contact.nickname
                      div(class: "type-h3 gl-muted", style: "margin-top: var(--gl-space-2xs);") { @contact.nickname }
                    end
                  end
                  # Only a picture earns this slot: an initials circle
                  # beside the name in type-h2 would repeat what the name
                  # already says. The dashboard rows keep theirs — there
                  # the avatar is the row's visual anchor, not a caption.
                  render Avatar.new(contact: @contact, size: "xl") if @contact.photo
                end
                # Only rendered when there's something to show: an empty
                # <dl> would still take up the gap card-body puts between
                # its children, leaving the header off-center in a card
                # with nothing else in it.
                dl(class: "detail-grid") { rows } if has_data?
              end
            end
          end
          # The stored card in its own card under the record: the bytes
          # are the truth the grid above interprets, and they stay
          # reachable — collapsed by default, because the record is
          # about the person and the bytes are about the wire. Native
          # <details>, because a disclosure needs no script (see
          # Layout — Alpine is loaded, and this is not what for);
          # and the one thing a card that will not parse has to show
          # (see Parser: no repair to make).
          div(class: "card") do
            div(class: "card-body") do
              details do
                summary(class: "type-label") { "raw vCard" }
                pre(class: "type-mono") { raw_card }
              end
            end
          end
        end
      end

      private

      #: () -> bool
      def has_data?
        @contact.phones.any? || @contact.emails.any? || @contact.addresses.any? ||
          !@birthday.nil? || @contact.notes.any?
      end

      # A missing TYPE parameter still gets a key: the fallback names
      # the kind of value, so no row renders unlabeled in the grid.
      # Every row that reads from a line hands it over, because which
      # group lends a row is a question about the line it came from.
      # The birthday hands over none: it is the model beside the card,
      # and a group holds only addresses and notes anyway (see
      # db/migrations/004_groups.rb).
      def rows
        @contact.phones.each { |phone| row(phone.type || "phone", phone.value, phone.line) }
        @contact.emails.each { |email| row(email.type || "email", email.value, email.line) }
        @contact.addresses.each { |address| row(address.type || "address", address_lines(address), address.line) }
        row("birthday", @birthday) if @birthday
        @contact.notes.each { |note| row("notes", note.value, note.line) }
      end

      # The type in one column and the value in the other, with the
      # group that lends the line named under the value when one does.
      # In the value cell rather than beside the type label: the type
      # column holds one thing for every row in the card
      # (docs/DESIGN.md, "Alignment is the layout"), and a mark on the
      # value is what says this address is the household's rather than
      # this contact's.
      #: (String type, String | Array[String] value, ?VCard::Parser::Line? line) -> void
      def row(type, value, line = nil)
        group = line && @contact.group_of(line)
        dt(class: "type-label") { type }
        dd(class: "type-body-sm") do
          render_value(value)
          # Gloss' Badge: a catalog mark annotating the row it sits on,
          # pinned to that row's first line at the right edge of the
          # value column (admin.css) — under the value it could be
          # read as marking the row below. No tone: the accent is held
          # constant across a view, and inherited is not a status.
          span(class: "badge") { group } if group
        end
      end

      # ADR's components as two display lines — street, then everything
      # after it — the same shape the design's own address rows settled
      # on. Presentation: the components themselves are Contact's.
      #: (Contact::Address address) -> Array[String]
      def address_lines(address)
        [
          [address.extended, address.street].compact.join(" "),
          [address.locality, address.region, address.postal_code].compact.join(", "),
          address.country,
        ].compact.reject { it.empty? }
      end

      #: (String | Array[String] value) -> void
      def render_value(value)
        if value.is_a?(Array)
          value.each { |line| div { line } }
        else
          div(style: "white-space: pre-wrap;") { value }
        end
      end

      # The stored card for display: byte for byte, except a value — a
      # property's or a parameter's — long enough to be a wall, which
      # renders as its octet count. The count says exactly what is
      # there; what it stands in for is not readable text.
      #: () -> String
      def raw_card
        @contact.vcard.lines.map { elide(it) }.join
      end

      # One line of the display card: verbatim when nothing in it runs
      # past ELIDE_ABOVE; rebuilt from its parse when something does,
      # each long value standing in as its count. The rebuild is the
      # parser's spelling rather than the bytes' — an elided line is a
      # rendering — and the line keeps its own terminator so the
      # card's line-break convention survives.
      #: (VCard::Parser::Line line) -> String
      def elide(line)
        property = line.property
        return elide_unparsed(line.verbatim) if property.nil?

        long = property.parameters.any? { |_, value| value.bytesize > ELIDE_ABOVE } ||
          property.value.bytesize > ELIDE_ABOVE
        return line.verbatim unless long

        header = property.group ? "#{property.group}.#{property.name}" : property.name
        params = property.parameters.map { |name, value| "#{name}=#{count_octets(value)}" }
        terminator = line.verbatim[/\r?\n\z/] || "\r\n"
        "#{[header, *params].join(';')}:#{count_octets(property.value)}#{terminator}"
      end

      # A value over the threshold stands in as its octet count;
      # anything shorter renders as it is.
      #: (String value) -> String
      def count_octets(value)
        value.bytesize > ELIDE_ABOVE ? "[#{value.bytesize} octets elided]" : value
      end

      # A line that would not parse has no structure to rebuild from,
      # so its value is elided by surgery on the bytes: everything up
      # to the first colon stands, and the rest is the count.
      #: (String verbatim) -> String
      def elide_unparsed(verbatim)
        prefix, value = verbatim.split(":", 2)
        return verbatim if value.nil?

        terminator = value.slice!(/\r?\n\z/) || ""
        "#{prefix}:#{count_octets(value)}#{terminator}"
      end
    end
  end
end
