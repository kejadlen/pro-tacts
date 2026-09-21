require "pro_tacts/admin/phlex"

require "pro_tacts/admin/group_filter"
require "pro_tacts/admin/group_label"

module ProTacts
  module Admin
    # The groups dialog on a contact's card, opened by the groups row's
    # "edit groups": ContactDialog's popover, over every group as a
    # checkbox, the contact's own checked. The save sends what the page
    # loaded with beside what it sends back (`was[]`), so the route can
    # move only what was toggled (Web#apply_groups).
    #
    # The filter over those boxes, the cap on how many stand shown, the
    # button that lifts it, and the offer to make the group the filter
    # names are Admin::GroupFilter's, shared with the import's own
    # picker (Admin::ImportGroups). The filter box sits outside the
    # form here, because Enter in a form's text box would save
    # mid-filter and there is somewhere outside to put it.
    #
    # Closing the popover puts the cap and the filter back. Alpine's
    # state belongs to the element, and a popover is hidden rather
    # than rebuilt, so without the reset a dialog reopens on whatever
    # the last visit left in it — a filter typed ten minutes ago, or
    # the whole list still unrolled.
    class GroupDialog < Phlex::HTML
      ID = "edit-groups" #: String
      FORM = "edit-groups-form" #: String

      # Alphabetical rather than the id order a tag keeps: this is a list
      # to find a name in, and nothing here stays put across a rename.
      # The groups this contact is in are what the cap spares: those
      # are the boxes the dialog is opened to untick.
      #: (contact: Contact, groups: Array[Store::Group]) -> void
      def initialize(contact:, groups:)
        @contact = contact
        @groups = groups.sort_by { it.label.downcase }
        @capped = GroupFilter.capped(
          @groups.map(&:id),
          joined: @groups.select { it.members.include?(contact.id) }.map(&:id),
        )
      end

      def view_template
        dialog(id: ID, popover: "auto", x_data: GroupFilter::STATE,
               "@toggle": "if ($event.newState === 'closed') { all = false; filter = '' }") do
          header { "Groups" }
          div(class: "field-stack") do
            render GroupFilter.new(autofocus: true)
            form(id: FORM, action: "/contacts/#{@contact.id}/groups", method: "post",
                 class: "field-stack", x_ref: "options") do
              @groups.each do |group|
                joined = group.members.include?(@contact.id)
                label(**GroupFilter.row(group.label, capped: @capped.include?(group.id))) do
                  input(type: "checkbox", name: "groups[]", value: group.id, checked: joined)
                  render GroupLabel.new(group:)
                end
                input(type: "hidden", name: "was[]", value: group.id) if joined
              end
              render GroupFilter::Fresh.new
            end
            render GroupFilter::Empty.new(any: @groups.any?)
            render GroupFilter::Rest.new(count: @groups.length) if @capped.any?
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
