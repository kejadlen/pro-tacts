require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/format"
require "pro_tacts/admin/group_label"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/list_item"

module ProTacts
  module Admin
    # GET /groups/:id — a group's card, and under it the contacts it
    # holds. Groups are records, not labels (docs/DESIGN.md,
    # "Relationships are navigable"), so the card is a contact's card
    # in every way that carries over: what the group lends on the same
    # type-and-value grid, and an attribute with no data gets no row.
    # The members are what a group is, so they are a list rather than a
    # row: /contacts' rows, narrowed to this group and in its order
    # (Format.sort_key). Under them the group's history, the change
    # log the contact page renders in this page's own shape. The whole
    # book comes in beside the members (Store#contacts) because that
    # log names the cards a join or a leave moved, and a name is what
    # a person reads; the members list is the narrowing of it.
    class GroupsShow < Phlex::HTML
      # @rbs @group: Group
      # @rbs @login: String
      # @rbs @reading: Contact
      # @rbs @contacts: Array[Contact]
      # @rbs @members: Array[Contact]
      # @rbs @changes: Array[Store::GroupChange]

      #: (group: Group, contacts: Array[Contact], changes: Array[Store::GroupChange], login: String) -> void
      def initialize(group:, contacts:, changes:, login:)
        @group = group
        @login = login
        @contacts = contacts
        @changes = changes
        @reading = group.reading
        @members = contacts.select { group.members.include?(it.id) }
          .sort_by { [Format.sort_key(it), it.id] }
      end

      def view_template
        render Layout.new(title: @group.label, login: @login) do
          div(class: "record") do
            div(class: "record-nav") do
              a(href: "/groups", class: "type-label") { "‹ groups" }
              a(href: "/groups/#{@group.id}/edit", class: "btn", data_size: "sm") { "edit" }
            end
            div(class: "card") do
              div(class: "card-body") do
                div(class: "detail-header") do
                  h1(class: "type-h2") { render GroupLabel.new(group: @group) }
                end
                # No grid for a group that lends nothing, so its name
                # sits alone in the card (.detail-header in admin.css).
                dl(class: "detail-grid") { rows } if lends?
              end
            end
          end
          members_list
          change_log
        end
      end

      private

      #: () -> bool
      def lends?
        @reading.addresses.any? || @reading.notes.any?
      end

      #: () -> void
      def rows
        @reading.addresses.each do |address|
          row(Format.type_label(nil, address.types, "address")) do
            Format.address_lines(address).each { |line| div { line } }
          end
        end
        @reading.notes.each do |note|
          row("notes") { div(style: "white-space: pre-wrap;") { note.value } }
        end
      end

      # Rendered even with no members, because its head holds the way
      # to add one. Membership is edited here rather than in the
      # editor, which edits only the lines the group holds; the link
      # opens the members screen (Admin::GroupsMembers), this list
      # made editable. It sits where a section's action does
      # (admin.css).
      #: () -> void
      def members_list
        section do
          div(class: "section-head") do
            h2(class: "type-label") { "members (#{@members.length})" }
            a(href: "/groups/#{@group.id}/members", class: "type-label") { "edit members" }
          end
          if @members.empty?
            p(class: "type-body-sm") { "No members yet." }
          else
            ul(class: "card") do
              @members.each do |member|
                render ListItem.new(
                  href: "/contacts/#{member.id}",
                  avatar: Avatar.new(contact: member, size: "lg"),
                ) { Format.name_label(member) }
              end
            end
          end
        end
      end

      #: (String type) { () -> void } -> void
      def row(type, &)
        dt(class: "type-label") { type }
        dd(class: "type-body-sm", &)
      end

      # What this group has done, under the members it holds: the
      # group's own log (Store#group_changes_of) in the contact page's
      # change-log shape — collapsed, because the record is about the
      # group and a history is about the writes.
      #: () -> void
      def change_log
        div(class: "card") do
          div(class: "card-body") do
            details do
              summary(class: "type-label") { "change log" }
              dl(class: "detail-grid change-log") { change_rows }
            end
          end
        end
      end

      # One row per entry, on the record's own grid — the contact
      # page's layout, its action in the type column and its moment
      # and detail in the value column. No etag beside the moment: a
      # group serves nothing, so no download exists for an etag to
      # describe. A `delete` entry has no arm — it would mean a page
      # rendered for a group that is gone, which is a 404 before any
      # of this runs.
      #: () -> void
      def change_rows
        @changes.each do |change|
          dt(class: "type-label") { change.action }
          dd(class: "type-body-sm") do
            div { Format.stamp(change.created_at) }
            case change.action
            when Store::GroupAction::CREATE then div { change.detail.fetch("name") || @group.id }
            when Store::GroupAction::RENAME then div { rename_detail(change.detail) }
            when Store::GroupAction::LINES then diff_lines(change.detail)
            when Store::GroupAction::JOIN, Store::GroupAction::LEAVE then member_link(change.detail)
            else raise "no arm for #{change.action}"
            end
          end
        end
      end

      # A rename's `was → name`, a null spelled as the group's id —
      # the label rule (Store#group_label), said of the names a group
      # no longer or not yet carries. The arrow, because the pair is
      # one fact about one moment and not two rows of it.
      #: (Hash[String, untyped] detail) -> String
      def rename_detail(detail)
        "#{detail.fetch("was") || @group.id} → #{detail.fetch("name") || @group.id}"
      end

      # A `lines` entry's moved lines, the contact page's own diff
      # rows: removed then added, the sign and not the color saying
      # which, each line elided the way a card's are. An empty diff is
      # a pure reorder — a real entry whose lines all stayed — so it
      # renders nothing rather than an empty block.
      #: (Hash[String, untyped] detail) -> void
      def diff_lines(detail)
        added = detail.fetch("added") #: Array[String]
        removed = detail.fetch("removed") #: Array[String]
        return if added.empty? && removed.empty?

        div(class: "diff type-mono") do
          removed.each { |line| div(class: "diff-removed") { "-#{Format.elide_text(line)}" } }
          added.each { |line| div(class: "diff-added") { "+#{Format.elide_text(line)}" } }
        end
      end

      # The card a join or a leave moved, linked to its page and
      # carrying its name — the members list's own bargain, the log
      # being for a person and a person reading names. A card since
      # deleted renders its id plain, the tombstone's text being all
      # that's left; a card that never was one is dropped by the save
      # (Web#apply_group_edit), so it cannot reach the log.
      #: (Hash[String, untyped] detail) -> void
      def member_link(detail)
        id = detail.fetch("card").to_s
        contact = @contacts.find { it.id == id }
        if contact
          a(href: "/contacts/#{id}") { Format.name_label(contact) }
        else
          div { id }
        end
      end
    end
  end
end
