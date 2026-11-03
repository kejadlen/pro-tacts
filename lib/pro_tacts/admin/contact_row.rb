require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/group_tag"

module ProTacts
  module Admin
    # A contact's row with its groups as chips under the name: /contacts'
    # rows (ContactsIndex), and the related list on a contact's page
    # (ContactsShow#related_list), where the chips are the groups the
    # two contacts share.
    #
    # Not a ListItem, whose one anchor wraps the whole row, because the
    # chips are links too and an anchor cannot hold one. The name is the
    # row's link and stretches over the row (.linked-row in admin.css);
    # the chips, each a link to its group's page as on the record page,
    # sit above that stretch.
    class ContactRow < Phlex::HTML
      # @rbs @contact: ListedContact
      # @rbs @groups: Array[ListedGroup]

      #: (contact: ListedContact, groups: Array[ListedGroup]) -> void
      def initialize(contact:, groups:)
        @contact = contact
        @groups = groups
      end

      def view_template
        li(class: "linked-row") do
          render Avatar.new(contact: @contact, size: "lg")
          div(style: "flex: 1; min-width: 0;") do
            a(href: "/contacts/#{@contact.id}", class: "row-link") { @contact.name_label }
            if @groups.any?
              div(class: "tag-set", style: "margin-top: var(--gl-space-3xs);") do
                @groups.each { |group| render GroupTag.new(group:) }
              end
            end
          end
        end
      end
    end
  end
end
