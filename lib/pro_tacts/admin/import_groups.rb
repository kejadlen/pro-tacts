require "pro_tacts/admin/phlex"

require "pro_tacts/admin/group_label"

module ProTacts
  module Admin
    # The groups one arriving contact will join, rendered into the
    # editor's own form on the import's review screen
    # (docs/plans/2026-09-21-import-a-vcf.md).
    #
    # Inside that form rather than beside it, because a staged
    # contact's groups are one more thing the walk is deciding about
    # it: one Save writes the card and the groups together, and there
    # is no second button to wonder about. That is the difference from
    # a stored contact, whose groups are a dialog on the details page
    # (Admin::GroupDialog) — there the card exists and a membership is
    # a write of its own, here neither is true until the confirm.
    #
    # Boxes over this book's own groups and nothing else. A group this
    # import invents is the one the review screen names for the whole
    # file: naming a new group per contact would be four hundred
    # chances to spell "Booles" two ways, and the contact's own page
    # can make one the moment it lands.
    class ImportGroups < Phlex::HTML
      # @rbs @groups: Array[Store::Group]
      # @rbs @joined: Array[String]

      # Alphabetical, the groups dialog's own order: this is a list to
      # find a name in, and nothing here stays put across a rename.
      #: (groups: Array[Store::Group], joined: Array[String]) -> void
      def initialize(groups:, joined:)
        @groups = groups.sort_by { it.label.downcase }
        @joined = joined
      end

      def view_template
        return if @groups.empty?

        div(class: "field-stack") do
          span(class: "type-label") { "groups" }
          @groups.each do |group|
            label do
              input(type: "checkbox", name: "groups[]", value: group.id,
                    checked: @joined.include?(group.id))
              render GroupLabel.new(group:)
            end
          end
        end
      end
    end
  end
end
