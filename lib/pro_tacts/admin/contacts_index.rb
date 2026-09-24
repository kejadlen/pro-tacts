require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/format"
require "pro_tacts/admin/group_label"
require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # GET /contacts — every contact in one list, sorted by last name:
    # the one screen that browses the whole contact set (docs/DESIGN.md,
    # "The core idea"), in Format.sort_key's order. Rows carry the
    # label the dashboard's rows do (Format.name_label) and the
    # contact's groups as chips under it.
    class ContactsIndex < Phlex::HTML
      # @rbs @rows: Array[Contact]
      # @rbs @login: String
      # @rbs @groups_of: Hash[String, Array[Store::Group]]

      #: (contacts: Array[Contact], groups: Array[Store::Group], login: String) -> void
      def initialize(contacts:, groups:, login:)
        @login = login
        @rows = contacts.sort_by { [Format.sort_key(it), it.id] }
        # Whole groups inverted into memberships, the way the dashboard
        # inverts them for search: which groups a contact is in is the
        # store's fact, read from that side once instead of per row.
        # all_groups arrives ordered by id, so the inversion keeps the
        # order a rename must not move a tag in.
        @groups_of = {}
        groups.each { |group| group.members.each { (@groups_of[it] ||= []) << group } }
      end

      def view_template
        render Layout.new(title: "Contacts", login: @login) do
          section do
            div(class: "section-head") do
              h2(class: "type-label") { "contacts (#{@rows.length})" }
            end
            if @rows.empty?
              p(class: "type-body-sm") { "No contacts yet." }
            else
              div(class: "letter-groups") do
                letter_groups.each do |letter, rows|
                  section do
                    h3(class: "type-label") { letter }
                    ul(class: "card") do
                      rows.each { render_row(it) }
                    end
                  end
                end
              end
            end
          end
        end
      end

      private

      #: (Contact contact) -> void
      def render_row(contact)
        # Not a ListItem, whose one anchor wraps the whole row, because
        # the chips are links too and an anchor cannot hold one. The
        # name is the row's link and stretches over the row
        # (.linked-row in admin.css); the chips, each a link to its
        # group's page as on the record page, sit above that stretch.
        li(class: "linked-row") do
          render Avatar.new(contact:, size: "lg")
          div(style: "flex: 1; min-width: 0;") do
            a(href: "/contacts/#{contact.id}", class: "row-link") { Format.name_label(contact) }
            groups = @groups_of[contact.id]
            if groups
              div(class: "tag-set", style: "margin-top: var(--gl-space-3xs);") do
                groups.each { |group| a(href: "/groups/#{group.id}", class: "tag") { render GroupLabel.new(group:) } }
              end
            end
          end
        end
      end

      # The rows cut at each first letter of Format.sort_key, the way
      # a phone's contacts list is: a contact files under the letter
      # it sorts by, so one with no family name files under its FN's.
      # An accent files with its base letter, whose rows it follows,
      # and anything that is no letter at all files under "#", after
      # Z. The rows arrive sorted, and group_by keeps their order
      # within each letter.
      #: () -> Array[[String, Array[Contact]]]
      def letter_groups
        @rows
          .group_by { letter_of(it) }
          .sort_by { |letter, _| [letter == "#" ? 1 : 0, letter] }
      end

      #: (Contact contact) -> String
      def letter_of(contact)
        base = Format.sort_key(contact).unicode_normalize(:nfd)[0].to_s
        base.match?(/[a-z]/) ? base.upcase : "#"
      end
    end
  end
end
