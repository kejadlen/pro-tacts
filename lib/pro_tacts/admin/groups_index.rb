require "pro_tacts/admin/phlex"

require "pro_tacts/admin/group_label"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/list_item"

module ProTacts
  module Admin
    # GET /groups — every group and how many cards it lends to, with
    # the create dialog riding along hidden the way the dashboard's
    # does (see ContactDialog for why a popover). A group needs nothing
    # to exist — no name, no lines, no members (db/migrations/
    # 005_group_identity.rb) — so the dialog's one field is optional,
    # and a create lands on the new group's editor, where everything
    # it will hold is added.
    class GroupsIndex < Phlex::HTML
      # @rbs @groups: Array[Store::Group]
      # @rbs @notice: String?

      #: (groups: Array[Store::Group], ?notice: String?) -> void
      def initialize(groups:, notice: nil)
        # The `sync:` groups first — the books a client syncs, which
        # are the store's own rather than anything a person made — and
        # the rest alphabetically. Sorted here rather than asked of the
        # store the way ContactsIndex sorts its rows: #all_groups is
        # ordered by id so that a rename never moves a tag, and only
        # this listing wants the reader's order. The key is the label
        # the row shows (GroupLabel), so a nameless group sorts by the
        # id it is shown by, and the id breaks a tie between two groups
        # labelled the same.
        @groups = groups.sort_by { [it.sync? ? 0 : 1, it.label.downcase, it.id] }
        @notice = notice
      end

      def view_template
        render Layout.new(title: "Groups", notice: @notice) do
          section do
            div(class: "section-head") do
              h2(class: "type-label") { "groups" }
              button(data_size: "sm", popovertarget: "new-group") { "add group" }
            end
            if @groups.empty?
              p(class: "type-body-sm") { "No groups yet." }
            else
              ul(class: "card") do
                @groups.each do |group|
                  render ListItem.new(
                    href: "/groups/#{group.id}",
                    trailing: members_label(group),
                  ) { render GroupLabel.new(group:) }
                end
              end
            end
          end
          new_group_dialog
        end
      end

      private

      #: (Store::Group group) -> String
      def members_label(group)
        count = group.members.length
        count == 1 ? "1 member" : "#{count} members"
      end

      #: () -> void
      def new_group_dialog
        dialog(id: "new-group", popover: "auto") do
          header { "New group" }
          form(id: "new-group-form", action: "/groups", method: "post") do
            label(class: "field") do
              plain "Name"
              input(type: "text", name: "name", autofocus: true)
            end
          end
          footer do
            button(type: "button", popovertarget: "new-group",
                   popovertargetaction: "hide") { "Cancel" }
            button(type: "submit", form: "new-group-form",
                   data: {variant: "primary"}) { "Create" }
          end
        end
      end
    end
  end
end
