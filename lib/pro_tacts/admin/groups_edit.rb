require "pro_tacts/admin/phlex"

require "pro_tacts/admin/contacts_edit"
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
    # Membership is checkboxes, native form state rather than script: a
    # member is a checked tag, unchecking one removes it on save, and
    # the add dialog lists every contact not yet in the group as an
    # unchecked box that submits with the form it sits outside of (the
    # `form` attribute) — the dialog being the view's one floated layer,
    # docs/DESIGN.md's rule for adding. A hidden empty `members[]`
    # makes the list present on every save of this form, so a POST that
    # carries no list at all is one that says nothing about membership
    # (#apply_edit's is-a-Hash posture) rather than one that empties it.
    class GroupsEdit < Phlex::HTML
      # @rbs @group: Store::Group
      # @rbs @reading: Contact
      # @rbs @members: Array[Contact]
      # @rbs @others: Array[Contact]
      # @rbs @notice: String?

      #: (group: Store::Group, contacts: Array[Contact], ?notice: String?) -> void
      def initialize(group:, contacts:, notice: nil)
        @group = group
        @reading = group.reading
        @members, @others = contacts.partition { group.members.include?(it.id) }
        @notice = notice
      end

      def view_template
        render Layout.new(title: "Edit #{@group.label}", notice: @notice) do
          div(class: "record") do
            div(class: "record-nav") do
              a(href: "/groups/#{@group.id}", class: "type-label") { "‹ #{@group.label}" }
              if @others.any?
                button(type: "button", data_size: "sm", popovertarget: "add-members") { "add members" }
              end
            end
            div(class: "card") do
              div(class: "card-body") do
                form(id: "group-form", action: "/groups/#{@group.id}", method: "post", class: "field-stack") do
                  input(type: "hidden", name: "version", value: @group.version)
                  input(type: "hidden", name: "members[]", value: "")
                  # The id as the blank's placeholder, because a group
                  # with no name is shown as its id everywhere else.
                  label(class: "field") do
                    span { "Name" }
                    input(type: "text", name: "name", value: @group.name,
                          placeholder: @group.id, autofocus: true)
                  end
                  members_row if @members.any?
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
          add_members_dialog if @others.any?
        end
      end

      private

      #: () -> void
      def members_row
        div(class: "field") do
          span { "Members" }
          div(class: "tag-set") do
            @members.each do |member|
              label(class: "tag") do
                input(type: "checkbox", name: "members[]", value: member.id, checked: true)
                plain(member.name || member.id)
              end
            end
          end
        end
      end

      # ContactsEdit#address_row, over a group's line.
      #: (Contact::Address address) -> void
      def address_row(address)
        div(class: "field", data: {blank_removes: address.po_box.nil?}) do
          span { address.type || "address" }
          div(class: "field-stack") do
            ContactsEdit::ADDRESS_FIELDS.each do |component, label|
              input(type: "text", name: "address[#{address.line.digest}][#{component}]",
                    value: address.public_send(component), placeholder: label, aria_label: label)
            end
          end
        end
      end

      # One address added per save, revealed on ask so no empty row
      # stands in the form until one is wanted (ContactsEdit#added_rows'
      # reason, and Alpine's). `display: contents` keeps both halves on
      # the form's own grid.
      #: () -> void
      def added_address_row
        div(x_data: "{ adding: false }", style: "display: contents;") do
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
          div(class: "field", "x-show": "!adding") do
            span
            button(type: "button", data_size: "sm", "@click": "adding = true") { "add address" }
          end
        end
      end

      #: () -> void
      def add_members_dialog
        dialog(id: "add-members", popover: "auto") do
          header { "Add members" }
          div(class: "field-stack") do
            @others.each do |contact|
              label do
                input(type: "checkbox", name: "members[]", value: contact.id, form: "group-form")
                plain(contact.name || contact.id)
              end
            end
          end
          footer do
            button(type: "button", popovertarget: "add-members",
                   popovertargetaction: "hide") { "Done" }
          end
        end
      end
    end
  end
end
