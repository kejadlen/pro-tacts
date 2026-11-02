require "pro_tacts/admin/phlex"

require "pro_tacts/admin/contacts_edit"
require "pro_tacts/admin/format"
require "pro_tacts/admin/group_label"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/record_card"

module ProTacts
  module Admin
    # GET /groups/:id/edit — a group's editor: Admin::ContactsEdit's
    # shape over what a group holds, which is a name and the addresses
    # and note it lends. The address rows are the contact editor's own
    # — a position in the entity's list, blank removes
    # (docs/plans/2026-09-05-web-card-editor.md) — and the save writes
    # the group's components (Web#apply_group_edit). A group's address
    # carries a label like a card's
    # (docs/plans/2026-10-25-contacts-on-entities.md), so its rows
    # carry the label field too. A group's version rides along hidden,
    # the snapshot guard a contact's etag is on its editor.
    #
    # Membership is edited from the group's card (Admin::GroupsShow),
    # not here: it is a relationship, not a component the group holds.
    # The form carries no `members[]`, so a save leaves membership as
    # it stands (Web#apply_group_edit).
    class GroupsEdit < Phlex::HTML
      # @rbs @group: Group
      # @rbs @login: String
      # @rbs @notice: String?

      # The form's id, for the footer's Save outside it.
      FORM = "group-form" #: String
      private_constant :FORM

      PHOTO_FORM = "group-photo-form" #: String
      private_constant :PHOTO_FORM

      #: (group: Group, login: String, ?notice: String?) -> void
      def initialize(group:, login:, notice: nil)
        @group = group
        @login = login
        @notice = notice
      end

      def view_template
        render Layout.new(title: "Edit #{@group.label}", login: @login, notice: @notice) do
          # The scope wraps the whole record because the add button sits
          # in the caption row above the card, where the contact editor's
          # add button sits, and the row it reveals is inside the form.
          div(x_data: "{ adding: false }") do
            render RecordCard.new(
              back: ["/groups/#{@group.id}", GroupLabel.new(group: @group)],
              nav: -> {
                button(type: "button", data_size: "sm", "x-show": "!adding",
                       "@click": "adding = true") { "add address" }
              },
              submit: "Save", form: FORM,
            ) do
              form(action: "/groups/#{@group.id}", method: "post", class: "field-stack", id: FORM) do
                input(type: "hidden", name: "version", value: @group.version)
                # The id as the blank's placeholder, because a group
                # with no name is shown as its id everywhere else. A
                # book's group keeps its name (Store#rename_group), so
                # the name is shown rather than offered: text where the
                # field would be, and a save that carries none keeps it
                # (Web#apply_group_edit).
                if @group.sync?
                  div(class: "field") do
                    span { "Name" }
                    span { @group.name }
                  end
                else
                  label(class: "field") do
                    span { "Name" }
                    input(type: "text", name: "name", value: @group.name, placeholder: @group.id, autofocus: true)
                  end
                end
                @group.addresses.each_with_index { |address, index|
                  address_row(address, index)
                }
                added_address_row
                # The group's note, the contact editor's own row: this
                # row edits it, and a save writes it.
                note = @group.note
                label(class: "field", data: {blank_removes: !!note}) do
                  span { "Note" }
                  textarea(name: "note", rows: 4,
                           placeholder: note ? "removed on save" : nil) { note.to_s }
                end
              end
            end
          end
          photo_section
          # The address rows' suggested labels, the contact editor's own
          # list (Admin::ContactsEdit#label_words).
          datalist(id: "address-labels") do
            Contact::Address.label_words.each { option(value: it) }
          end
        end
      end

      private

      # The group's photo, set or removed on its own rather than with
      # the form above: it lends nothing, so it has no place in the
      # version guard or the lines the save splices, and an upload
      # needs a multipart form the editor's save does not.
      #: () -> void
      def photo_section
        render RecordCard.new(
          nav: -> {
            span(class: "type-label") { "photo" }
            if @group.photo
              form(action: "/groups/#{@group.id}/photo", method: "post") do
                button(type: "submit", name: "remove", value: "1", data_size: "sm") { "remove photo" }
              end
            end
          },
          submit: "Upload", form: PHOTO_FORM,
        ) do
          form(action: "/groups/#{@group.id}/photo", method: "post", enctype: "multipart/form-data",
               class: "field-stack", id: PHOTO_FORM) do
            img(class: "group-photo", src: "/groups/#{@group.id}/photo", alt: "") if @group.photo
            label(class: "field") do
              span { @group.photo ? "Replace" : "Photo" }
              input(type: "file", name: "photo", accept: "image/jpeg,image/png,image/gif", required: true)
            end
          end
        end
      end

      # ContactsEdit#address_row, over a group's component — the label
      # field included, a group's address carrying a label like a
      # card's (the class comment's plan).
      #: (ContactDetails::Address address, Integer index) -> void
      def address_row(address, index)
        div(class: "field", data: {blank_removes: address.po_box.empty?}) do
          input(type: "text", class: "row-label", name: "address[#{index}][label]", value: address.label,
                autocomplete: "off", list: "address-labels", placeholder: "address", aria_label: "address label")
          div(class: "field-stack") do
            ContactsEdit::ADDRESS_FIELDS.each do |component, label|
              input(type: "text", name: "address[#{index}][#{component}]",
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
