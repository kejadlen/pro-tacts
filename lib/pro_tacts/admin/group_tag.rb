require "pro_tacts/admin/phlex"

require "pro_tacts/admin/format"
require "pro_tacts/admin/group_label"
require "pro_tacts/admin/icons"

module ProTacts
  module Admin
    # A contact's group as a chip linking to the group, marked when the
    # group has a photo so a reader knows its page holds one, and naming
    # its first few members in Gloss's tooltip.
    class GroupTag < Phlex::HTML
      SHOWN = 5 #: Integer

      # @rbs @group: Group
      # @rbs @members: Array[ListedContact]

      #: (group: Group) -> void
      def initialize(group:)
        @group = group
        @members = group.listed_members || raise(ArgumentError, "group #{group.id} was read without its members listed")
      end

      def view_template
        shown = @members.take(SHOWN)
        rest = @members.drop(SHOWN)
        span do
          a(href: "/groups/#{@group.id}", class: "tag") do
            render Icon.new(:image, size: 12) if @group.photo
            render GroupLabel.new(group: @group)
            span(class: "gl-visually-hidden") { "has a photo" } if @group.photo
          end
          # Not a ul, which Gloss's .card-body ul sets as prose.
          ol(role: "tooltip") do
            shown.each { |contact| li { Format.name_label(contact) } }
            li { "and #{rest.length} more" } if rest.any?
          end
        end
      end
    end
  end
end
