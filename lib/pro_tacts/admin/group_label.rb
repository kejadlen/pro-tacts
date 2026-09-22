require "pro_tacts/admin/phlex"

module ProTacts
  module Admin
    # A group's name wherever one is shown. A group needs no name
    # (db/migrations/005_group_identity.rb), and one without is shown by
    # its id, marked `data-nameless` so admin.css can set it as an
    # identifier rather than let it pass for a name.
    class GroupLabel < Phlex::HTML
      # @rbs @group: Store::Group | Store::GroupChoice

      # A Group or the lighter GroupChoice a picker carries: this reads
      # only the name and the id, which both hold.
      #: (group: Store::Group | Store::GroupChoice) -> void
      def initialize(group:)
        @group = group
      end

      def view_template
        name = @group.name
        if name
          plain name
        else
          span(data: {nameless: true}) { @group.id }
        end
      end
    end
  end
end
