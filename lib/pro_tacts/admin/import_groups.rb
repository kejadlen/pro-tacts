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
    # A box per group this book has, then a box per group this import
    # has been told to make and has not made yet, then somewhere to
    # name another. A named group is not created here: it is made at
    # the confirm (Import::Write#group_id), because a group created
    # while the walk is still going is a group left behind by an
    # import that was abandoned. So it rides as a name until then, and
    # shows as a ticked box like any other so that it can be unticked.
    class ImportGroups < Phlex::HTML
      # @rbs @groups: Array[Store::Group]
      # @rbs @joined: Array[String]
      # @rbs @named: Array[String]

      # Alphabetical, the groups dialog's own order: this is a list to
      # find a name in, and nothing here stays put across a rename.
      # `joined` is the ids ticked so far, `named` the groups this
      # import is making that do not exist yet.
      #: (groups: Array[Store::Group], joined: Array[String], named: Array[String]) -> void
      def initialize(groups:, joined:, named:)
        @groups = groups.sort_by { it.label.downcase }
        @joined = joined
        @named = named
      end

      def view_template
        div(class: "field-stack") do
          span(class: "type-label") { "groups" }
          @groups.each do |group|
            label do
              input(type: "checkbox", name: "groups[]", value: group.id,
                    checked: @joined.include?(group.id))
              render GroupLabel.new(group:)
            end
          end
          # Italic and muted, the shape the groups dialog gives a name
          # that is not a group yet (Admin::GroupDialog): the box
          # behaves like the ones above it, and the styling is what
          # says this one is about to be made.
          @named.each do |name|
            label do
              input(type: "checkbox", name: "named[]", value: name, checked: true)
              span(class: "gl-muted", style: "font-style: italic;") { name }
            end
          end
          # One at a time, and blank by default: a name typed here is
          # added to the list above on save, where it can be read back
          # and taken off again.
          label(class: "field") do
            span { "New group" }
            input(type: "text", name: "new", placeholder: "made when the import is confirmed")
          end
        end
      end
    end
  end
end
