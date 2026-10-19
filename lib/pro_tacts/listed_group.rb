require "pro_tacts/group"
require "pro_tacts/listed_contact"

module ProTacts
  # A group read with its members as a list shows them, in Contact#<=>'s
  # order, for the screens that tag groups (Admin::GroupTag). A group
  # composed into a card for a client is a plain Group, and reads none.
  #
  # Signed in sig/pro_tacts/listed_group.rbs, for Group's reason.
  # @rbs skip
  class ListedGroup < Group
    def initialize(listed_members:, **)
      @listed_members = listed_members
      super(**)
    end

    attr_reader :listed_members
  end
end
