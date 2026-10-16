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
    # and note it lends. The address rows are the
    # contact editor's own — addressed by digest, blank removes
    # (docs/plans/2026-09-05-web-card-editor.md) — and the save runs
    # the contact editor's own splice over the group's lines
    # (Web#apply_group_edit). A group's version rides along hidden, the
    # snapshot guard a contact's etag is on its editor.
    #
    # Membership is edited from the group's card (Admin::GroupsShow),
    # not here: it is a relationship, not a line the group holds. The
    # form carries no `members[]`, so a save leaves membership as it
    # stands (Web#apply_group_edit).
    class GroupsEdit < Phlex::HTML
      # @rbs @group: Group
      # @rbs @login: String
      # @rbs @reading: Contact
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
        @reading = group.reading
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
                @reading.addresses.each { |address| address_row(address) }
                added_address_row
                # Every NOTE, joined, the contact editor's own rule:
                # this row edits one, and a save writes one.
                note = CardForm.note_of(@reading)
                label(class: "field", data: {blank_removes: !!note}) do
                  span { "Note" }
                  textarea(name: "note", rows: 4,
                           placeholder: note ? "removed on save" : nil) { note.to_s }
                end
              end
            end
          end
          photo_section
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

      # ContactsEdit#address_row, over a group's line.
      #: (Contact::Address address) -> void
      def address_row(address)
        div(class: "field", data: {blank_removes: address.po_box.nil?}) do
          span { Format.type_label(nil, address.types, "address") }
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
