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
    # Alpine filters, matching each row's lowercased label in
    # data-label so no group's name is spliced into script; a row it
    # hides still submits its box. The filter sits outside the form,
    # because Enter in a form's text box would save mid-filter.
    #
    # Only LIMIT rows stand shown, the rest hidden behind the filter or
    # the button that reveals them
    # (docs/plans/2026-09-22-a-few-groups-at-a-time.md). Every group is
    # still rendered: the filter is client-side, so a group that is not
    # in the page is one nothing in the dialog can reach.
    #
    # A filter naming no group exactly also offers itself as a new
    # group (`new`), created and joined by the save. Unchecked until
    # ticked: a filter is usually half a name typed to find a group,
    # and a save must not create "boo" on the way to Booles.
    class GroupDialog < Phlex::HTML
      ID = "edit-groups" #: String
      FORM = "edit-groups-form" #: String

      # How many rows a dialog opens with. The popover does not scroll
      # (Gloss gives a dialog `height: fit-content` and
      # `overflow: hidden`), so a list longer than the screen is a
      # Save clipped off the bottom of it: enough rows here that a
      # household's whole list is on the screen, few enough that a
      # long one still ends in its footer.
      LIMIT = 8 #: Integer

      # `needle` is the filter as the rows are matched against it, one
      # definition for the three readers of it. `visible` is what the
      # cap adds to `shows`: a capped row joins the list once the
      # filter is typed into or the whole list is asked for, and a
      # filter is the one of the two that can reach a single group
      # without the rest.
      STATE = "{ filter: '', all: false, " \
              "get needle() { return this.filter.trim().toLowerCase() }, " \
              "get labels() { return [...this.$refs.options.querySelectorAll('[data-label]')]" \
              ".map(row => row.dataset.label) }, " \
              "shows(label) { return label.includes(this.needle) }, " \
              "visible(row) { return this.shows(row.dataset.label) && " \
              "(this.all || this.needle !== '' || !('capped' in row.dataset)) }, " \
              "get none() { return !this.labels.some(label => this.shows(label)) }, " \
              "get creatable() { return this.needle !== '' && !this.labels.includes(this.needle) } }" #: String

      # Alphabetical rather than the id order a tag keeps: this is a list
      # to find a name in, and nothing here stays put across a rename.
      #: (contact: Contact, groups: Array[Store::Group]) -> void
      def initialize(contact:, groups:)
        @contact = contact
        @groups = groups.sort_by { it.label.downcase }
        # A group the contact is in is never capped, however far down
        # the list it sorts: those are the boxes the dialog is opened
        # to untick, and one hidden from the person unticking it makes
        # the dialog disagree with the card it was opened from. They
        # take rows from the limit rather than standing outside it, so
        # the list is the limit or the membership, whichever is longer.
        joined, rest = @groups.partition { it.members.include?(contact.id) }
        @capped = rest.drop((LIMIT - joined.length).clamp(0, LIMIT)).map(&:id)
      end

      def view_template
        dialog(id: ID, popover: "auto", x_data: STATE) do
          header { "Groups" }
          div(class: "field-stack") do
            input(type: "search", placeholder: "Filter or add groups", aria_label: "Filter or add groups",
                  autofocus: true, x_model: "filter")
            form(id: FORM, action: "/contacts/#{@contact.id}/groups", method: "post",
                 class: "field-stack", x_ref: "options") do
              @groups.each do |group|
                joined = group.members.include?(@contact.id)
                label(data: {label: group.label.downcase, capped: @capped.include?(group.id)},
                      ":hidden": "!visible($el)") do
                  input(type: "checkbox", name: "groups[]", value: group.id, checked: joined)
                  render GroupLabel.new(group:)
                end
                input(type: "hidden", name: "was[]", value: group.id) if joined
              end
              template(x_if: "creatable") do
                label do
                  input(type: "checkbox", name: "new", ":value": "filter.trim()")
                  span(class: "gl-muted", style: "font-style: italic;", x_text: "filter.trim()")
                end
              end
            end
            template(x_if: "none && !creatable") do
              p(class: "gl-muted") { @groups.empty? ? "No groups yet." : "No groups match." }
            end
            rest_button if @capped.any?
          end
          footer do
            button(type: "button", popovertarget: ID, popovertargetaction: "hide") { "Cancel" }
            button(type: "submit", form: FORM, data: {variant: "primary"}) { "Save" }
          end
        end
      end

      private

      # The way past the cap for someone who is looking rather than
      # naming: the filter reaches a group already known by name, this
      # reaches the list. It counts the whole list rather than the part
      # under the cap, that being the number a person is deciding
      # whether to read. It stands down while the filter is typed into,
      # which lifts the cap itself.
      #: () -> void
      def rest_button
        button(type: "button", data_size: "sm", "x-show": "!all && needle === ''",
               "@click": "all = true") { "show all #{@groups.length} groups" }
      end
    end
  end
end
