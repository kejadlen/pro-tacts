require "pro_tacts/admin/phlex"

require "pro_tacts/admin/contacts_edit"
require "pro_tacts/admin/format"
require "pro_tacts/admin/group_label"
require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # GET /groups/:id/edit — a group's editor: Admin::ContactsEdit's
    # shape over what a group holds, which is a name, the addresses and
    # note it lends, and who it lends them to. The address rows are the
    # contact editor's own — addressed by digest, blank removes
    # (docs/plans/2026-09-05-web-card-editor.md) — and the save runs
    # the contact editor's own splice over the group's lines
    # (Web#apply_group_edit). A group's version rides along hidden, the
    # snapshot guard a contact's etag is on its editor.
    #
    # Membership is edited from the group's card (Admin::GroupsShow),
    # not here: it is a relationship, not a line the group holds. The
    # form carries
    # no `members[]`, so a save says nothing about membership
    # (#apply_edit's is-a-Hash posture) and leaves it as it stands.
    class GroupsEdit < Phlex::HTML
      # @rbs @group: Store::Group
      # @rbs @reading: Contact
      # @rbs @notice: String?

      #: (group: Store::Group, ?notice: String?) -> void
      def initialize(group:, notice: nil)
        @group = group
        @reading = group.reading
        @notice = notice
      end

      def view_template
        render Layout.new(title: "Edit #{@group.label}", notice: @notice) do
          # The scope wraps the whole record because the add button sits
          # in the caption row above the card, where the contact editor's
          # add button sits, and the row it reveals is inside the form.
          div(class: "record", x_data: "{ adding: false }") do
            div(class: "record-nav") do
              a(href: "/groups/#{@group.id}", class: "type-label") do
                plain "‹ "
                render GroupLabel.new(group: @group)
              end
              button(type: "button", data_size: "sm", "x-show": "!adding",
                     "@click": "adding = true") { "add address" }
            end
            div(class: "card") do
              div(class: "card-body") do
                form(action: "/groups/#{@group.id}", method: "post", class: "field-stack") do
                  input(type: "hidden", name: "version", value: @group.version)
                  # The id as the blank's placeholder, because a group
                  # with no name is shown as its id everywhere else.
                  label(class: "field") do
                    span { "Name" }
                    input(type: "text", name: "name", value: @group.name,
                          placeholder: @group.id, autofocus: true)
                  end
                  @reading.addresses.each { |address| address_row(address) }
                  added_address_row
                  # The first NOTE, the contact editor's own rule: this
                  # row edits one, and a save writes one.
                  note = @reading.notes.first&.value
                  label(class: "field", data: {blank_removes: !!note}) do
                    span { "Note" }
                    textarea(name: "note", rows: 4,
                             placeholder: note ? "removed on save" : nil) { note.to_s }
                  end
                  div(class: "form-actions") do
                    button(type: "submit", data: {variant: "primary"}) { "Save" }
                    a(href: "/groups/#{@group.id}", class: "btn") { "Cancel" }
                  end
                end
              end
            end
          end
        end
      end

      private

      # ContactsEdit#address_row, over a group's line.
      #: (Contact::Address address) -> void
      def address_row(address)
        div(class: "field", data: {blank_removes: address.po_box.nil?}) do
          span { Format.type_label(address.types, "address") }
          div(class: "field-stack") do
            ContactsEdit::ADDRESS_FIELDS.each do |component, label|
              input(type: "text", name: "address[#{address.line.digest}][#{component}]",
                    value: address.public_send(component), placeholder: label, aria_label: label)
            end
          end
        end
      end

      # One address added per save, revealed by the caption row's button
      # so no empty row stands in the form until one is wanted
      # (ContactsEdit#added_rows' reason, and Alpine's).
      #: () -> void
      def added_address_row
        template("x-if": "adding") do
          div(class: "field") do
            span { "address" }
            div(class: "field-stack") do
              ContactsEdit::ADDRESS_FIELDS.each_with_index do |(component, label), index|
                input(type: "text", name: "new_address[0][#{component}]", placeholder: label,
                      aria_label: label, "x-init": index.zero? ? "$el.focus()" : nil)
              end
            end
          end
        end
      end
    end
  end
end
