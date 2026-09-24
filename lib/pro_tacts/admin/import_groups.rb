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
    # a write of its own, here neither exists until that Save.
    #
    # A box per group this book has, then a box per group this card
    # has been told to make and has not made yet, then the filter
    # itself offered as another. The two a card comes in under
    # whatever else is ticked stand among them rather than out of
    # sight, ticked: everyone's book, and the group for the import.
    # Both can be unticked — an arrival that does not belong with the
    # lot is a thing the walk is for deciding, and so is a card that
    # is to sit on the server without going out to anybody's phone. The filter, the cap on how many rows
    # stand shown and the button that lifts it are the dialog's
    # (Admin::GroupFilter,
    # docs/plans/2026-09-22-a-few-groups-at-a-time.md): a book with
    # three hundred groups buries either picker, and this is the one
    # the walk opens once per contact.
    #
    # A named group is not created here: it is made by the Save, with
    # the contact it was named for (Import::Write#group_id), because a
    # group created while a card is still being looked over is one
    # left behind if that card is never saved. So it rides as a name
    # until then, and shows as a ticked box like any other so that it
    # can be unticked.
    class ImportGroups < Phlex::HTML
      # @rbs @groups: Array[Store::GroupChoice]
      # @rbs @joined: Array[String]
      # @rbs @named: Array[String]
      # @rbs @capped: Array[String]
      # @rbs @was: Array[String]

      # The `sync:` groups lead (GroupChoice#<=>), then largest first
      # and alphabetical among groups the same size: the groups an
      # arrival is likeliest to belong in are the ones most of the
      # book already does, so they are the rows the cap leaves
      # standing, and the filter reaches the rest. The groups dialog
      # keeps the plain listing order — there a contact's groups are
      # being looked over, not guessed at. `groups` is every group as
      # a choice, counted rather than its members read
      # (Store#group_choices); `joined` the ids ticked, `named` the
      # groups this card is making that do not exist yet.
      #
      # Those last two are empty whenever the card is opened, and hold
      # what was ticked only when a save was sent back to be fixed
      # (Web#card_screen): nothing is staged between screens, because
      # the Save that would have staged it is the Save that writes the
      # contact.
      #
      # Both are rows the cap spares, for the dialog's own reason: a
      # box this contact has already been given is one the walk came
      # back to untick. The names take rows from the limit without
      # being in the list the cap reads, so they are counted into it
      # rather than listed in it.
      #
      # `was` is the groups a contact the book already has is in, for a
      # card being folded into it (Import::Merge): sent back beside the
      # boxes, the groups dialog's own `was[]`, so the save moves only
      # what was toggled (Web#apply_groups). A new contact is in none.
      #: (groups: Array[Store::GroupChoice], joined: Array[String], named: Array[String], ?was: Array[String]) -> void
      def initialize(groups:, joined:, named:, was: [])
        @groups = groups.sort_by { [it.sync? ? 0 : 1, -it.member_count, it.label.downcase] }
        @joined = joined
        @named = named
        @was = was
        @capped = GroupFilter.capped(@groups.map(&:id), joined:, shown: named.length)
      end

      def view_template
        div(class: "field-stack", x_data: GroupFilter::STATE) do
          span(class: "type-label") { "groups" }
          @was.each do |id|
            input(type: "hidden", name: "was[]", value: id)
          end
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
            # about to be made. Always shown and never capped, being
            # ticked (`visible`'s own rule); the `data-label` is for
            # `creatable`, so that a name this import is already
            # making is not offered as a name to make.
            @named.each do |name|
              label(**GroupFilter.row(name)) do
                input(type: "checkbox", name: "named[]", value: name, checked: true)
                span(class: "gl-muted", style: "font-style: italic;") { name }
              end
            end
            # The same row client-side, for names the offer's tick has
            # committed since this page loaded: the tick is what
            # commits (Admin::GroupFilter), so the name stands here
            # rather than riding the filter that named it.
            render GroupFilter::Named.new
            render GroupFilter::Fresh.new
          end
          render GroupFilter::Empty.new(any: @groups.any? || @named.any?)
          render GroupFilter::Rest.new(count: @groups.length) if @capped.any?
        end
      end
    end
  end
end
