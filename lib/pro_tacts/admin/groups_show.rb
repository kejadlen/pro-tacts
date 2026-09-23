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
    # (Format.sort_key).
    class GroupsShow < Phlex::HTML
      # @rbs @group: Store::Group
      # @rbs @reading: Contact
      # @rbs @members: Array[Contact]

      #: (group: Store::Group, members: Array[Contact]) -> void
      def initialize(group:, members:)
        @group = group
        @reading = group.reading
        @members = members.sort_by { [Format.sort_key(it), it.id] }
      end

      def view_template
        render Layout.new(title: @group.label) do
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
      # editor, which edits only the lines the group holds. The link
      # sits where a section's action does (admin.css), and has no
      # href until the members screen exists.
      #: () -> void
      def members_list
        section do
          div(class: "section-head") do
            h2(class: "type-label") { "members (#{@members.length})" }
            a(class: "type-label") { "edit members" }
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
    end
  end
end
