require "pro_tacts/admin/phlex"

require "pro_tacts/admin/contact_dialog"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/recent_row"
require "pro_tacts/admin/upcoming_birthdays"

module ProTacts
  module Admin
    # GET / — the dashboard (docs/DESIGN.md): recency in the primary
    # column, the birthdays the year is about to bring in the ambient
    # one beside it. It answers no query; the search is the header's
    # dialog, on this screen as on every other
    # (docs/plans/2026-09-30-live-search.md). The create dialog rides
    # along hidden on every render — a popover opens where it sits, so
    # the add button needs nothing from the server but the page it is
    # already on.
    class Dashboard < Phlex::HTML
      # How many rows recently updated lists, here and on the search
      # page before a query (Web#search_results).
      RECENT_LIMIT = 10

      # @rbs @login: String
      # @rbs @upcoming: Array[Store::UpcomingBirthday]
      # @rbs @rows: Array[Store::RecentContact]
      # @rbs @notice: String?

      #: (recent: Array[Store::RecentContact], upcoming: Array[Store::UpcomingBirthday], login: String, ?notice: String?) -> void
      def initialize(recent:, upcoming:, login:, notice: nil)
        @login = login
        @upcoming = upcoming
        @notice = notice
        @rows = recent.first(RECENT_LIMIT)
      end

      def view_template
        render Layout.new(title: "Home", login: @login, wide: true, notice: @notice) do
          div(class: "dashboard") do
            section do
              div(class: "section-head") do
                h2(class: "type-label") { "recently updated" }
                # A button, not a link: it changes the page's state
                # rather than navigating, and the Popover API is what
                # it invokes (see ContactDialog).
                button(data_size: "sm", popovertarget: "new-contact") { "add contact" }
              end
              if @rows.empty?
                p(class: "type-body-sm") { "No contacts yet." }
              else
                ul(class: "card") do
                  @rows.each { render RecentRow.new(row: it) }
                end
              end
            end
            render UpcomingBirthdays.new(upcoming: @upcoming)
          end
          # In the page but out of the columns: a popover opens from
          # wherever it sits, and hidden is its resting state.
          render ContactDialog.new
        end
      end
    end
  end
end
