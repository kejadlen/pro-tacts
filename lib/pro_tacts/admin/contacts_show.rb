require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/format"
require "pro_tacts/admin/group_label"
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

      # The groups come from the store beside the contact rather than
      # off it: a contact's card carries what its groups lend it, never
      # which groups those are (Store#groups_of). Required, and not
      # defaulted to none, so a caller cannot render a contact as
      # belonging to nothing by forgetting to ask. The change log is
      # beside it for the same reason and required for the stronger
      # one: a card with no entries is a card whose history was lost,
      # and an empty default would render that as an ordinary quiet
      # record.
      #: (Contact contact, Array[Store::Group] groups, Array[Store::Change] changes) -> void
      def initialize(contact:, groups:, changes:)
        @contact = contact
        @groups = groups
        @changes = changes
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
          # What this card has done, under the bytes it currently is:
          # the log the sync tokens count on (Store#changes_of), which
          # until now nothing here showed. Collapsed and in the raw
          # card's shape for the raw card's reason — the record is
          # about the person, and a sequence of etags is about the
          # wire — and last of the three, because a history is read
          # after the thing that has one.
          div(class: "card") do
            div(class: "card-body") do
              details do
                summary(class: "type-label") { "change log" }
                dl(class: "detail-grid change-log") { change_rows }
              end
            end
          end
        end
      end

      private

      #: () -> bool
      def has_data?
        @contact.phones.any? || @contact.emails.any? || @contact.addresses.any? ||
          !@birthday.nil? || @contact.notes.any? || @groups.any?
      end

      # A missing TYPE parameter still gets a key: the fallback names
      # the kind of value, so no row renders unlabeled in the grid.
      # Every row that reads from a line hands it over, because which
      # group lends a row is a question about the line it came from.
      # The birthday hands over none: it is the model beside the card,
      # and a group holds only addresses and notes anyway (see
      # db/migrations/004_groups.rb).
      def rows
        groups_row if @groups.any?
        @contact.phones.each do |phone|
          row(phone.type || "phone", phone.value, phone.line)
        end
        @contact.emails.each do |email|
          row(email.type || "email", email.value, email.line)
        end
        @contact.addresses.each do |address|
          row(address.type || "address", Format.address_lines(address), address.line)
        end
        row("birthday", @birthday) if @birthday
        @contact.notes.each do |note|
          row("notes", note.value, note.line)
        end
      end

      # Membership as its own row, above the card's own: what a contact
      # belongs to frames the values under it, and several of those
      # values are the group's rather than the contact's. Every tag opens
      # the group it names (docs/DESIGN.md, "Relationships are
      # navigable"), the other half of the member tags on a group's own
      # card (Admin::GroupsShow).
      #: () -> void
      def groups_row
        dt(class: "type-label") { "groups" }
        dd(class: "type-body-sm") do
          div(class: "tag-set") do
            @groups.each { group_tag(it) }
          end
        end
      end

      #: (Store::Group group) -> void
      def group_tag(group)
        a(href: "/groups/#{group.id}", class: "tag") { render GroupLabel.new(group:) }
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
          # The groups row's own tag, pinned to this row's first line
          # at the right edge of the value column (admin.css) — under
          # the value it could be read as marking the row below.
          group_tag(group) if group
        end
      end

      #: (String | Array[String] value) -> void
      def render_value(value)
        if value.is_a?(Array)
          value.each do |line|
            div { line }
          end
        else
          div(style: "white-space: pre-wrap;") { value }
        end
      end

      # One row per entry, on the record's own grid: the action in the
      # type column, because it is the kind of thing the row is, and
      # the moment, the etag, and the lines the write moved in the
      # value column. All three are the value — the etag is what the
      # card hashed to at that write and the one hash in the schema
      # that is stored rather than derived (AGENTS.md), so it is shown
      # whole. A delete's etag is null, and the row is its moment and
      # the card it carried away: a tombstone hashes nothing.
      #: () -> void
      def change_rows
        @changes.each do |change|
          dt(class: "type-label") { change.action }
          dd(class: "type-body-sm") do
            div { Format.stamp(change.created_at) }
            # <abbr>, because a cut hash is an abbreviation of one and
            # the title is where the whole value stays reachable. A
            # tooltip is hover's, so it is out of reach on a touch
            # screen — the reason the shortened form has to be enough
            # to tell two writes apart on its own, and the full etag a
            # thing to reach for rather than to read.
            if change.etag
              abbr(class: "type-mono", title: Format.etag_digest(change.etag)) do
                Format.short_etag(change.etag)
              end
            end
            diff_lines(change.diff)
          end
        end
      end

      # Removed lines and then added ones, each marked the way a diff
      # marks them — the sign, not the color, is what says which, so a
      # row reads the same to someone who cannot tell the two hues
      # apart. Order within each is the card's own (CardDiff), and a
      # write that moved no line at all renders nothing rather than an
      # empty block: a rewrite storing what was already there is a real
      # entry with nothing to show.
      #: (CardDiff diff) -> void
      def diff_lines(diff)
        return if diff.empty?

        div(class: "diff type-mono") do
          # Named rather than `it`: Phlex yields the component to an
          # element's block, so an inner `it` is this view, not the
          # line.
          diff.removed.each { |line| div(class: "diff-removed") { "-#{elide_text(line)}" } }
          diff.added.each { |line| div(class: "diff-added") { "+#{elide_text(line)}" } }
        end
      end

      # A diff's line elided the way the raw card's are. It arrives as
      # text rather than as a card's line, so it is read back into one
      # to reach #elide's rebuild — worth the parse: the first entry of
      # a card with a picture is the whole card, and a base64 payload
      # is exactly the wall ELIDE_ABOVE exists for. A line the parser
      # cannot read still elides, by the byte surgery #elide falls back
      # to; a line the terminator was stripped from keeps none, so the
      # rebuilt one sheds the CRLF #elide gives it.
      #: (String text) -> String
      def elide_text(text)
        line = VCard::Parser.lines(text).first
        line ? elide(line).chomp : text
      end

      # The stored card for display: byte for byte, except a value long
      # enough to be a wall. The count says exactly what is there; what
      # it stands in for is not readable text.
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
