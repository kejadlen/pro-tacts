require "pro_tacts/admin/phlex"

require "pro_tacts/admin/group_filter"
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
    # has been told to make and has not made yet, then the filter
    # itself offered as another. The filter, the cap on how many rows
    # stand shown and the button that lifts it are the dialog's
    # (Admin::GroupFilter,
    # docs/plans/2026-09-22-a-few-groups-at-a-time.md): a book with
    # three hundred groups buries either picker, and this is the one
    # the walk opens once per contact.
    #
    # A named group is not created here: it is made at the confirm
    # (Import::Write#group_id), because a group created while the walk
    # is still going is a group left behind by an import that was
    # abandoned. So it rides as a name until then, and shows as a
    # ticked box like any other so that it can be unticked.
    class ImportGroups < Phlex::HTML
      # @rbs @groups: Array[Store::GroupChoice]
      # @rbs @joined: Array[String]
      # @rbs @named: Array[String]
      # @rbs @capped: Array[String]

      # Alphabetical, the groups dialog's own order: this is a list to
      # find a name in, and nothing here stays put across a rename.
      # `groups` is every group as a choice, no members read
      # (Store#group_choices); `joined` the ids ticked so far, `named`
      # the groups this import is making that do not exist yet.
      #
      # Both of those are rows the cap spares, for the dialog's own
      # reason: a box this contact has already been given is one the
      # walk came back to untick. The names take rows from the limit
      # without being in the list the cap reads, so they are counted
      # into it rather than listed in it.
      #: (groups: Array[Store::GroupChoice], joined: Array[String], named: Array[String]) -> void
      def initialize(groups:, joined:, named:)
        @groups = groups.sort_by { it.label.downcase }
        @joined = joined
        @named = named
        @capped = GroupFilter.capped(@groups.map(&:id), joined:, shown: named.length)
      end

      def view_template
        div(class: "field-stack", x_data: GroupFilter::STATE) do
          span(class: "type-label") { "groups" }
          # Enter guarded rather than the filter moved: the dialog
          # keeps its filter outside the form it filters, and here
          # there is no outside — the boxes are the editor's own
          # fields (GroupFilter#initialize).
          render GroupFilter.new(in_form: true)
          div(class: "field-stack", x_ref: "options") do
            @groups.each do |group|
              label(**GroupFilter.row(group.label, capped: @capped.include?(group.id))) do
                input(type: "checkbox", name: "groups[]", value: group.id,
                      checked: @joined.include?(group.id))
                render GroupLabel.new(group:)
              end
            end
            # Italic and muted, the shape the groups dialog gives a
            # name that is not a group yet: the box behaves like the
            # ones above it, and the styling is what says this one is
            # about to be made. Filterable like them too, so that a
            # name this import is already making is not offered as a
            # name to make, and never capped, being ticked.
            @named.each do |name|
              label(**GroupFilter.row(name)) do
                input(type: "checkbox", name: "named[]", value: name, checked: true)
                span(class: "gl-muted", style: "font-style: italic;") { name }
              end
            end
            render GroupFilter::Fresh.new
          end
          render GroupFilter::Empty.new(any: @groups.any? || @named.any?)
          render GroupFilter::Rest.new(count: @groups.length) if @capped.any?
        end
      end
    end
  end
end
