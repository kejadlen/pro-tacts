require "pro_tacts/admin/phlex"

require "pro_tacts/admin/search_field"

module ProTacts
  module Admin
    # The search on a wide screen: a popover the header's button opens
    # (Layout) over whatever screen it is on, holding the search
    # (SearchField). A phone goes to the search page instead
    # (SearchPage); why the two differ, and why a dialog at all, is
    # docs/plans/2026-09-30-live-search.md.
    #
    # The Popover API does the opening and closing — the button, Esc,
    # a click outside — and `autofocus` lands in the input each time
    # it opens. `/` opens it from anywhere a key is not already typing
    # into something (docs/DESIGN.md, "The core idea"). What was typed
    # stays when it closes, so reopening lands on the same answer.
    class SearchDialog < Phlex::HTML
      ID = "search" #: String

      # `/` opens the dialog unless it is being typed into a field —
      # the dialog's own input among them — or the dialog is already
      # open, where showPopover would throw.
      SLASH = "if (!$el.matches(':popover-open') && " \
              "!$event.target.closest('input, textarea, select, [contenteditable]')) " \
              "{ $event.preventDefault(); $el.showPopover() }" #: String
      private_constant :SLASH

      def view_template
        dialog(id: ID, popover: "auto", class: "search-dialog", x_data: true,
               "@keydown.slash.window": SLASH) do
          render SearchField.new
        end
      end
    end
  end
end
