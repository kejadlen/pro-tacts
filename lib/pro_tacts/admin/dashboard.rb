require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/contact_dialog"
require "pro_tacts/admin/format"
require "pro_tacts/admin/group_label"
require "pro_tacts/admin/list_item"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/search"
require "pro_tacts/admin/upcoming_birthdays"

module ProTacts
  module Admin
    # GET / — the dashboard (docs/DESIGN.md): the search in the page
    # header, recency in the primary column, the birthdays the year is
    # about to bring in the ambient one beside it. A query narrows the
    # contacts column to matches across every contact, in the order
    # Search.contacts ranks them; an empty query
    # shows the ten most recently updated. The create dialog rides
    # along hidden on every render — a popover opens where it sits, so
    # the add button needs nothing from the server but the page it is
    # already on.
    class Dashboard < Phlex::HTML
      RECENT_LIMIT = 10
      private_constant :RECENT_LIMIT

      # @rbs @query: String
      # @rbs @login: String
      # @rbs @upcoming: Array[Store::UpcomingBirthday]
      # @rbs @labels: Hash[String, Array[String]]
      # @rbs @groups: Array[Group]
      # @rbs @rows: Array[Store::RecentContact]
      # @rbs @notice: String?

      # The groups arrive whole because a search answers from both
      # sides of the relationship: a group is findable by its own name,
      # and a contact by the names of the groups it is in.
      #: (recent: Array[Store::RecentContact], upcoming: Array[Store::UpcomingBirthday], query: String?, login: String, groups: Array[Group], ?notice: String?) -> void
      def initialize(recent:, upcoming:, query:, login:, groups:, notice: nil)
        @query = query.to_s.strip
        @login = login
        @upcoming = upcoming
        @notice = notice
        @labels = {}
        groups.each { |group| group.members.each { (@labels[it] ||= []) << group.label } }
        @groups = @query.empty? ? [] : Search.groups(groups, query: @query)
        @rows = @query.empty? ? recent.first(RECENT_LIMIT) : Search.contacts(recent, query: @query, labels: @labels)
      end

      def view_template
        render Layout.new(title: "Home", login: @login, wide: true, query: @query,
                          autofocus: @query.empty?, notice: @notice) do
          div(class: "dashboard") do
            section do
              div(class: "section-head") do
                h2(class: "type-label") { @query.empty? ? "recently updated" : "contacts" }
                # A button, not a link: it changes the page's state
                # rather than navigating, and the Popover API is what
                # it invokes (see ContactDialog).
                button(data_size: "sm", popovertarget: "new-contact") { "add contact" }
              end
              if @rows.empty?
                p(class: "type-body-sm") { @query.empty? ? "No contacts yet." : "No contacts match." }
              else
                ul(class: "card") do
                  @rows.each do
                    render_row(it)
                  end
                end
              end
              group_results if @groups.any?
            end
            render UpcomingBirthdays.new(upcoming: @upcoming)
          end
          # In the page but out of the columns: a popover opens from
          # wherever it sits, and hidden is its resting state.
          render ContactDialog.new(query: @query)
        end
      end

      private

      # The groups whose names match, under the contacts: a group is a
      # record the search reaches as surely as a contact is
      # (docs/DESIGN.md, "When adding something new").
      #: () -> void
      def group_results
        div(class: "section-head group-results") do
          h2(class: "type-label") { "groups" }
        end
        ul(class: "card") do
          @groups.each do |group|
            render ListItem.new(href: "/groups/#{group.id}") { render GroupLabel.new(group:) }
          end
        end
      end

      #: (Store::RecentContact row) -> void
      def render_row(row)
        render ListItem.new(
          href: "/contacts/#{row.contact.id}",
          avatar: Avatar.new(contact: row.contact, size: "lg"),
          trailing: Format.time_ago(row.updated_at),
        ) { Format.name_label(row.contact) }
      end
    end
  end
end
