require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/format"
require "pro_tacts/admin/group_label"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/list_item"

module ProTacts
  module Admin
    # GET /contacts — every contact in one list, sorted by last name:
    # the one screen that browses the whole contact set (docs/DESIGN.md,
    # "The core idea"). The sort key is N's family name (RFC 2426
    # section 3.1.2), falling back the way Format.initials does — FN
    # for a card with no N, the id for a card with no name at all.
    # Rows carry the label the dashboard's rows do (Format.name_label)
    # and the contact's groups as chips under it.
    class ContactsIndex < Phlex::HTML
      # @rbs @rows: Array[Contact]
      # @rbs @groups_of: Hash[String, Array[Store::Group]]

      #: (contacts: Array[Contact], groups: Array[Store::Group]) -> void
      def initialize(contacts:, groups:)
        @rows = contacts.sort_by { [sort_key(it), it.id] }
        # Whole groups inverted into memberships, the way the dashboard
        # inverts them for search: which groups a contact is in is the
        # store's fact, read from that side once instead of per row.
        # all_groups arrives ordered by id, so the inversion keeps the
        # order a rename must not move a tag in.
        @groups_of = {}
        groups.each { |group| group.members.each { (@groups_of[it] ||= []) << group } }
      end

      def view_template
        render Layout.new(title: "Contacts") do
          section do
            div(class: "section-head") do
              h2(class: "type-label") { "contacts (#{@rows.length})" }
            end
            if @rows.empty?
              p(class: "type-body-sm") { "No contacts yet." }
            else
              ul(class: "card") do
                @rows.each do
                  render_row(it)
                end
              end
            end
          end
        end
      end

      private

      # The order a contact lists under, case-insensitive so the card's
      # spelling of a family name does not move it.
      #: (Contact contact) -> String
      def sort_key(contact)
        family, = contact.name_components || []
        (family || contact.name || contact.id).to_s.downcase
      end

      #: (Contact contact) -> void
      def render_row(contact)
        render ListItem.new(
          href: "/contacts/#{contact.id}",
          avatar: Avatar.new(contact:, size: "lg"),
        ) do
          div { Format.name_label(contact) }
          groups = @groups_of[contact.id]
          if groups
            # Spans rather than the record page's linked tags, because
            # the row is a link and an anchor cannot hold one; the
            # weight reset keeps the chips from inheriting the name's.
            div(class: "tag-set", style: "margin-top: var(--gl-space-3xs); font-weight: 400;") do
              groups.each { |group| span(class: "tag") { render GroupLabel.new(group:) } }
            end
          end
        end
      end
    end
  end
end
