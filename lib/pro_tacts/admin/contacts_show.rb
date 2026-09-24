require "pro_tacts/admin/phlex"

require "pro_tacts/admin/contact_card"
require "pro_tacts/admin/format"
require "pro_tacts/admin/group_dialog"

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
      # The groups come from the store beside the contact rather than
      # off it: a contact's card carries what its groups lend it, never
      # which groups those are (Store#groups_of). Required, and not
      # defaulted to none, so a caller cannot render a contact as
      # belonging to nothing by forgetting to ask. The change log is
      # beside it for the same reason and required for the stronger
      # one: a card with no entries is a card whose history was lost,
      # and an empty default would render that as an ordinary quiet
      # record. Every group is the groups dialog's (GroupDialog).
      #: (Contact contact, String login, Array[Store::Group] groups, Array[Store::GroupChoice] all_groups, Array[Store::Change] changes, ?notice: String?) -> void
      def initialize(contact:, login:, groups:, all_groups:, changes:, notice: nil)
        @contact = contact
        @login = login
        @groups = groups
        @all_groups = all_groups
        @changes = changes
        @notice = notice
      end

      def view_template
        render Layout.new(title: @contact.name || @contact.id, login: @login, notice: @notice) do
          # The back-link line and the record card are one block, the
          # line its caption row: spaced like the dashboard's
          # section-head over its card (see .record in admin.css), not
          # like a block of the column's own. The raw vCard card below
          # stays a sibling at the column's rhythm. The card itself is
          # ContactCard's, the one renderer of a contact's details,
          # with the groups dialog on the page to back its row's
          # button.
          div(class: "record") do
            div(class: "record-nav") do
              a(href: "/", class: "type-label") { "‹ contacts" }
              a(href: "/contacts/#{@contact.id}/edit", class: "btn", data_size: "sm") { "edit" }
            end
            render ContactCard.new(contact: @contact, groups: @groups, dialog: true)
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
          # No row, so outside the record's grid. The groups this
          # contact is in are the tag row's already (Store#groups_of),
          # so the dialog is told which boxes to check rather than
          # reading every group's members to work it out.
          render GroupDialog.new(contact: @contact, groups: @all_groups, joined: @groups.map(&:id))
        end
      end

      private

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
          diff.removed.each { |line| div(class: "diff-removed") { "-#{Format.elide_text(line)}" } }
          diff.added.each { |line| div(class: "diff-added") { "+#{Format.elide_text(line)}" } }
        end
      end

      # The stored card for display: byte for byte, except a value long
      # enough to be a wall. The count says exactly what is there; what
      # it stands in for is not readable text.
      #: () -> String
      def raw_card
        @contact.vcard.lines.map { Format.elide_line(it) }.join
      end
    end
  end
end
