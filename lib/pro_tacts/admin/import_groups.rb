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
    # A filter over a box per group this book has, then a box per
    # group this import has been told to make and has not made yet,
    # then the filter itself offered as another. The filter is the
    # dialog's own (Admin::GroupFilter): a book with three hundred
    # groups is a screen either picker would otherwise bury, and this
    # one is walked once per contact.
    #
    # A named group is not created here: it is made at the confirm
    # (Import::Write#group_id), because a group created while the walk
    # is still going is a group left behind by an import that was
    # abandoned. So it rides as a name until then, and shows as a
    # ticked box like any other so that it can be unticked.
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
        div(class: "field-stack", x_data: GroupFilter::STATE) do
          span(class: "type-label") { "groups" }
          # Enter guarded rather than the filter moved: the dialog
          # keeps its filter outside the form it filters, and here
          # there is no outside — the boxes are the editor's own
          # fields (GroupFilter#initialize).
          render GroupFilter.new(in_form: true)
          div(class: "field-stack", x_ref: "options") do
            @groups.each do |group|
              label(**GroupFilter.row(group.label)) do
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
            # name to make.
            @named.each do |name|
              label(**GroupFilter.row(name)) do
                input(type: "checkbox", name: "named[]", value: name, checked: true)
                span(class: "gl-muted", style: "font-style: italic;") { name }
              end
            end
            render GroupFilter::Fresh.new
          end
          render GroupFilter::Empty.new(any: @groups.any? || @named.any?)
        end
      end
    end
  end
end
