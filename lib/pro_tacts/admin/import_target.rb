require "pro_tacts/admin/phlex"

module ProTacts
  module Admin
    # What a row's Save will write, at the top of the walk's editor: the
    # card as a new contact, or folded into one the book already has
    # that it looks like (Import::Match,
    # docs/plans/2026-09-23-merging-on-import.md). Rendered only where
    # there is a contact to offer — a toggle with one side is not a
    # choice.
    #
    # Gloss's segmented tabs, a filter over one record rather than
    # navigation between pages, and links rather than buttons: each
    # side is its own rendering of the editor, over the arriving card
    # or over the contact it would update (Import::Merge), so choosing
    # one is a GET for that screen. The form carries the choice back
    # as `into`, the contact the save updates; none is a new contact.
    class ImportTarget < Phlex::HTML
      # @rbs @row: String
      # @rbs @matches: Array[::ProTacts::Contact]
      # @rbs @into: ::ProTacts::Contact?

      # `row` is the row's own screen, `matches` the contacts it looks
      # like, and `into` the one this screen is updating, if any.
      #: (row: String, matches: Array[::ProTacts::Contact], into: ::ProTacts::Contact?) -> void
      def initialize(row:, matches:, into:)
        @row = row
        @matches = matches
        @into = into
      end

      # A div around the tablist, because the form it sits in is a
      # column that stretches its children and the segments are a
      # track of their own width, centered over the editor (the
      # `.import-target` rule in admin.css).
      def view_template
        div(class: "import-target") do
          div(role: "tablist", aria_label: "Import as", data: {variant: "segmented"}) do
            tab("#{@row}?into=", "new contact", @into.nil?)
            @matches.each do |match|
              tab("#{@row}?into=#{match.id}", "update #{match.name || match.id}", @into&.id == match.id)
            end
          end
          input(type: "hidden", name: "into", value: @into.id) if @into
        end
      end

      private

      #: (String href, String label, bool selected) -> void
      def tab(href, label, selected)
        a(href:, role: "tab", aria_selected: selected.to_s) { label }
      end
    end
  end
end
