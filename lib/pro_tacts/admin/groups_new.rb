require "pro_tacts/admin/member_picker"

module ProTacts
  module Admin
    # GET /contacts/:id/groups/new — the picker (Admin::MemberPicker)
    # over a group not yet made, opened from a contact card's "new"
    # (Admin::ContactCard) with that contact ticked. Its Create is the
    # create (Web#apply_new_group), so a group someone backs out of is
    # never made, and with nothing yet to toggle against it sends no
    # `was`.
    class GroupsNew < MemberPicker
      # @rbs @contact: Contact

      #: (contact: Contact, contacts: Array[ListedContact], login: String, ?notice: String?) -> void
      def initialize(contact:, contacts:, login:, notice: nil)
        @contact = contact
        super(contacts:, login:, notice:)
      end

      private

      #: () -> String
      def title = "New group"

      #: () -> String
      def action = "/contacts/#{@contact.id}/groups/new"

      #: () -> [String, (String | Phlex::HTML)]
      def back = ["/contacts/#{@contact.id}", @contact.name || @contact.id]

      # The verb the two create dialogs end on (GroupsIndex,
      # ContactDialog).
      #: () -> String
      def submit = "Create"

      #: () -> Array[String]
      def ticked = [@contact.id]

      #: () -> Array[String]
      def was = []
    end
  end
end
