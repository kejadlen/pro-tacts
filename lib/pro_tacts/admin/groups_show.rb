require "pro_tacts/admin/phlex"

require "pro_tacts/admin/format"
require "pro_tacts/admin/group_label"
require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # GET /groups/:id — a group's card. Groups are records, not labels
    # (docs/DESIGN.md, "Relationships are navigable"), so this is a
    # contact's card in every way that carries over: what the group
    # lends on the same type-and-value grid, and an attribute with no
    # data gets no row. Its members are tags that open their records,
    # the other half of the tags on a member's own card.
    class GroupsShow < Phlex::HTML
      # @rbs @group: Store::Group
      # @rbs @reading: Contact
      # @rbs @members: Array[Contact]

      #: (group: Store::Group, members: Array[Contact]) -> void
      def initialize(group:, members:)
        @group = group
        @reading = group.reading
        @members = members
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
                  h1(class: "type-h2", style: "margin: 0;") { render GroupLabel.new(group: @group) }
                end
                # Never empty, unlike ContactsShow's: the members row
                # always renders (#members_row).
                dl(class: "detail-grid") { rows }
              end
            end
          end
        end
      end

      private

      # Members first, the order a contact's card puts its groups in:
      # the relationship frames the rows under it.
      #: () -> void
      def rows
        members_row
        @reading.addresses.each do |address|
          row(Format.type_label(address.types, "address")) do
            Format.address_lines(address).each { |line| div { line } }
          end
        end
        @reading.notes.each do |note|
          row("notes") { div(style: "white-space: pre-wrap;") { note.value } }
        end
      end

      # Rendered even with no members, because its link is the way to
      # add one. Membership is edited here rather than in the editor,
      # which edits only the lines the group holds. The link sits at the
      # row's right edge where a lent row's badge sits (admin.css), and
      # has no href until the members screen exists.
      #: () -> void
      def members_row
        row("members") do
          if @members.any?
            div(class: "tag-set") do
              @members.each do |member|
                a(href: "/contacts/#{member.id}", class: "tag") { member.name || member.id }
              end
            end
          end
          a(class: "type-label") { "edit members" }
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
