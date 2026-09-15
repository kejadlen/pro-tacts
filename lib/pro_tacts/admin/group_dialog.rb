require "pro_tacts/admin/phlex"

require "pro_tacts/admin/group_label"

module ProTacts
  module Admin
    # The groups dialog on a contact's card, opened by the groups row's
    # "edit groups": ContactDialog's popover, over every group as a
    # checkbox, the contact's own checked. The save sends what the page
    # loaded with beside what it sends back (`was[]`), so the route can
    # move only what was toggled (Web#apply_groups).
    #
    # Alpine only filters, matching each row's lowercased label in
    # data-label so no group's name is spliced into script; a row it
    # hides still submits its box. The filter sits outside the form,
    # because Enter in a form's text box would save mid-filter.
    class GroupDialog < Phlex::HTML
      ID = "edit-groups" #: String
      FORM = "edit-groups-form" #: String

      STATE = "{ filter: '', " \
              "shows(label) { return label.includes(this.filter.trim().toLowerCase()) }, " \
              "get none() { return ![...this.$refs.options.querySelectorAll('[data-label]')]" \
              ".some(row => this.shows(row.dataset.label)) } }" #: String

      # Alphabetical rather than the id order a tag keeps: this is a list
      # to find a name in, and nothing here stays put across a rename.
      #: (contact: Contact, groups: Array[Store::Group]) -> void
      def initialize(contact:, groups:)
        @contact = contact
        @groups = groups.sort_by { it.label.downcase }
      end

      def view_template
        dialog(id: ID, popover: "auto", x_data: STATE) do
          header { "Groups" }
          div(class: "field-stack") do
            input(type: "search", placeholder: "Filter groups", aria_label: "Filter groups",
                  autofocus: true, x_model: "filter")
            form(id: FORM, action: "/contacts/#{@contact.id}/groups", method: "post",
                 class: "field-stack", x_ref: "options") do
              @groups.each do |group|
                joined = group.members.include?(@contact.id)
                label(data: {label: group.label.downcase}, ":hidden": "!shows($el.dataset.label)") do
                  input(type: "checkbox", name: "groups[]", value: group.id, checked: joined)
                  render GroupLabel.new(group:)
                end
                input(type: "hidden", name: "was[]", value: group.id) if joined
              end
            end
            template(x_if: "none") { p(class: "gl-muted") { "No groups match." } }
          end
          footer do
            button(type: "button", popovertarget: ID, popovertargetaction: "hide") { "Cancel" }
            button(type: "submit", form: FORM, data: {variant: "primary"}) { "Save" }
          end
        end
      end
    end
  end
end
