require "phlex"

require "pro_tacts/admin/contact_fields"
require "pro_tacts/admin/format"
require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # GET /admin/contacts/:id — a contact's card, read-only. Follows
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
      #: (Contact contact) -> void
      def initialize(contact:)
        @contact = contact
        @fields = ContactFields.from(contact)
      end

      def view_template
        render Layout.new(title: @fields.name || @contact.id) do
          a(href: "/admin/contacts", class: "type-label") { "‹ contacts" }
          div(class: "card") do
            div(class: "card-body") do
              div(style: "display: flex; align-items: center; gap: var(--gl-space-s);") do
                span(class: "avatar", data_size: "lg") { Format.initials(@fields.name || @contact.id) }
                h1(class: "type-h2", style: "margin: 0;") { @fields.name || @contact.id }
              end
              dl(class: "detail-grid") { rows }
            end
          end
        end
      end

      private

      def rows
        @fields.phones.each { |phone| row(phone.type, phone.value) }
        @fields.emails.each { |email| row(email.type, email.value) }
        @fields.addresses.each { |address| row(address.type || "address", address.lines) }
        row("birthday", @fields.birthday) if @fields.birthday
        row("notes", @fields.notes) if @fields.notes
      end

      #: (String? type, String | Array[String] value) -> void
      def row(type, value)
        dt(class: "type-label") { type }
        dd(class: "type-body-sm") { render_value(value) }
      end

      #: (String | Array[String] value) -> void
      def render_value(value)
        if value.is_a?(Array)
          value.each { |line| div { line } }
        else
          div(style: "white-space: pre-wrap;") { value }
        end
      end
    end
  end
end
