require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/format"
require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # GET /contacts — every contact in one list, sorted by last name:
    # the one screen that browses the whole contact set (docs/DESIGN.md,
    # "The core idea"). The sort key is N's family name (RFC 2426
    # section 3.1.2), falling back the way Format.initials does — FN
    # for a card with no N, the id for a card with no name at all.
    # Rows carry the label the dashboard's rows do (Format.name_label).
    class ContactsIndex < Phlex::HTML
      # @rbs @rows: Array[Contact]

      #: (contacts: Array[Contact]) -> void
      def initialize(contacts:)
        @rows = contacts.sort_by { [sort_key(it), it.id] }
      end

      def view_template
        render Layout.new(title: "Contacts") do
          section do
            div(class: "section-head") do
              h2(class: "type-label") { "contacts" }
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
        li do
          a(href: "/contacts/#{contact.id}") do
            render Avatar.new(contact:, size: "lg")
            div(style: "flex: 1; min-width: 0; font-weight: 550;") { Format.name_label(contact) }
          end
        end
      end
    end
  end
end
