require "pro_tacts/admin/phlex"

require "pro_tacts/admin/group_label"
require "pro_tacts/admin/icons"

module ProTacts
  module Admin
    # A contact's group as a chip linking to the group, marked when the
    # group has a photo so a reader knows its page holds one.
    class GroupTag < Phlex::HTML
      # @rbs @group: Group

      #: (group: Group) -> void
      def initialize(group:)
        @group = group
      end

      def view_template
        a(href: "/groups/#{@group.id}", class: "tag") do
          render Icon.new(:image, size: 12) if @group.photo
          render GroupLabel.new(group: @group)
          span(class: "gl-visually-hidden") { "has a photo" } if @group.photo
        end
      end
    end
  end
end
