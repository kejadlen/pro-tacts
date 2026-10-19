require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/format"
require "pro_tacts/admin/group_filter"
require "pro_tacts/admin/group_label"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/record_card"

module ProTacts
  module Admin
    # GET /groups/:id/members — the members screen, the groups
    # dialog's mirror (Admin::GroupDialog): a box per contact in the
    # book, ticked for the ones in the group, and a save that moves
    # only what was toggled (`was[]`, Web#apply_members). A screen
    # and not the dialog's popover for the reason the cap gives from
    # the other side: a contact's groups are a handful, a group's
    # members are the whole book, and a page scrolls where a popover
    # clips. The list is the show screen's own (admin.css, the rows
    # carrying a checkbox where a row's link stands), so the screen
    # reads as that list made editable rather than as a form's option
    # stack (Admin::GroupsShow).
    #
    # The form owns the picker's Alpine state and so wraps both
    # cards, the record's own above and the list under it — $refs and
    # the state reach only inside their x-data element — which puts
    # the filter inside the form it filters: Enter in it is guarded
    # rather than submitted, the import's own answer where there is
    # no outside to stand in (Admin::GroupFilter), whose filter, cap,
    # and show-all button these are, without its offer.
    #
    # The same screen picks a group's first members before the group
    # exists: a contact card's "new" (Admin::ContactCard) opens it
    # with that contact ticked, and its Create is the create
    # (Web#apply_new_group), so a group someone backs out of is never
    # made.
    class GroupsMembers < Phlex::HTML
      # @rbs @login: String
      # @rbs @notice: String?
      # @rbs @contacts: Array[ListedContact]
      # @rbs @title: String
      # @rbs @action: String
      # @rbs @back: [String, (String | Phlex::HTML)]
      # @rbs @submit: String
      # @rbs @ticked: Array[String]
      # @rbs @was: Array[String]
      # @rbs @capped: Array[String]

      # The form's id, for the footer's Save outside it.
      FORM = "members-form" #: String
      private_constant :FORM

      # `from` is the record the screen was opened from: a group's
      # page edits that group's members, and a contact's card starts a
      # group with that contact in it. `was` is what the page loaded
      # with, which a group not yet made has none of.
      #: (from: Group | Contact, contacts: Array[ListedContact], login: String, ?notice: String?) -> void
      def initialize(from:, contacts:, login:, notice: nil)
        @login = login
        @notice = notice
        # The order the show screen's list reads (Format.sort_key),
        # which is the order the book is browsed in everywhere else.
        @contacts = contacts.sort_by { [Format.sort_key(it), it.id] }
        case from
        in Group
          @title = "Members of #{from.label}"
          @action = "/groups/#{from.id}/members"
          @back = ["/groups/#{from.id}", GroupLabel.new(group: from)]
          @submit = "Save"
          @ticked = from.members
          @was = from.members
        in Contact
          @title = "New group"
          @action = "/contacts/#{from.id}/groups/new"
          @back = ["/contacts/#{from.id}", from.name || from.id]
          # The verb the two create dialogs end on (GroupsIndex,
          # ContactDialog).
          @submit = "Create"
          @ticked = [from.id]
          @was = []
        end
        # The ticked are never capped (GroupFilter.capped).
        @capped = GroupFilter.capped(@contacts.map(&:id), joined: @ticked)
      end

      def view_template
        render Layout.new(title: @title, login: @login, notice: @notice) do
          form(action: @action, method: "post", class: "member-picker", id: FORM, x_data: GroupFilter::STATE) do
            render RecordCard.new(back: @back, submit: @submit, form: FORM) do
              render GroupFilter.new(autofocus: true, in_form: true, placeholder: "Filter contacts")
            end
            div(class: "member-list") do
              ul(class: "card", x_ref: "options") do
                @contacts.each do |contact|
                  # The row's label is the name the lists show
                  # (Format.name_label), nickname and all, because
                  # that is the name a person filters by; the row
                  # itself is the li, so the cap hides the whole of
                  # it and not the box alone (Admin::GroupFilter).
                  li(**GroupFilter.row(Format.name_label(contact),
                                       capped: @capped.include?(contact.id))) do
                    label do
                      input(type: "checkbox", name: "members[]", value: contact.id, checked: @ticked.include?(contact.id))
                      render Avatar.new(contact:, size: "lg")
                      div(style: "flex: 1; min-width: 0; font-weight: 550;") { Format.name_label(contact) }
                    end
                    input(type: "hidden", name: "was[]", value: contact.id) if @was.include?(contact.id)
                  end
                end
              end
              render GroupFilter::Empty.new(any: @contacts.any?, offer: false, noun: "contacts")
              render GroupFilter::Rest.new(count: @contacts.length, noun: "contacts") if @capped.any?
            end
          end
        end
      end
    end
  end
end
