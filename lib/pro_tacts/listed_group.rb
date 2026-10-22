require "pro_tacts/group"
require "pro_tacts/listed_contact"

module ProTacts
  # A group read with its first few members as a list shows them, in
  # Contact#<=>'s order, for the screens that tag groups
  # (Admin::GroupTag): the tag names those and counts the rest off
  # #members. A group composed into a card for a client is a plain
  # Group, and reads none.
  #
  # Signed in sig/pro_tacts/listed_group.rbs, for Group's reason.
  # @rbs skip
  class ListedGroup < Group
    def initialize(first_members:, **)
      @first_members = first_members
      super(**)
    end

    attr_reader :first_members
  end
end
