require "pro_tacts/admin/group_label"
require "pro_tacts/admin/member_picker"

module ProTacts
  module Admin
    # GET /groups/:id/members — the picker (Admin::MemberPicker) over
    # a group that exists, its Save moving only what was toggled.
    class GroupsMembers < MemberPicker
      # @rbs @group: Group

      #: (group: Group, contacts: Array[ListedContact], login: String) -> void
      def initialize(group:, contacts:, login:)
        @group = group
        super(contacts:, login:)
      end

      private

      #: () -> String
      def title = "Members of #{@group.label}"

      #: () -> String
      def action = "/groups/#{@group.id}/members"

      #: () -> [String, (String | Phlex::HTML)]
      def back = ["/groups/#{@group.id}", GroupLabel.new(group: @group)]

      #: () -> String
      def submit = "Save"

      #: () -> Array[String]
      def ticked = @group.members

      #: () -> Array[String]
      def was = @group.members
    end
  end
end
