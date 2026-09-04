require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/contact_dialog"
require "pro_tacts/admin/format"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/upcoming_birthdays"

module ProTacts
  module Admin
    # GET / — the dashboard (docs/DESIGN.md): the search in the page
    # header, recency in the primary column, the birthdays the year is
    # about to bring in the ambient one beside it. A query narrows the
    # contacts column to matches across every contact; an empty query
    # shows the ten most recently updated. The create dialog rides
    # along hidden on every render — a popover opens where it sits, so
    # the add button needs nothing from the server but the page it is
    # already on.
    class ContactsIndex < Phlex::HTML
      RECENT_LIMIT = 10
      private_constant :RECENT_LIMIT

      Row = Data.define(:contact, :updated_at)
      private_constant :Row

      # @rbs @query: String
      # @rbs @upcoming: Array[Store::UpcomingBirthday]
      # @rbs @rows: Array[Row]
      # @rbs @notice: String?

      #: (recent: Array[Store::RecentContact], upcoming: Array[Store::UpcomingBirthday], query: String?, ?notice: String?) -> void
      def initialize(recent:, upcoming:, query:, notice: nil)
        @query = query.to_s.strip
        @upcoming = upcoming
        @notice = notice
        rows = recent.map { Row.new(contact: it.contact, updated_at: it.updated_at) }
        @rows = @query.empty? ? rows.first(RECENT_LIMIT) : rows.select { matches?(it, @query) }
      end

      def view_template
        render Layout.new(title: "Contacts", wide: true, search: @query, notice: @notice) do
          div(class: "dashboard") do
            section do
              div(class: "section-head") do
                h2(class: "type-label") { @query.empty? ? "recently updated" : "results" }
                # A button, not a link: it changes the page's state
                # rather than navigating, and the Popover API is what
                # it invokes (see ContactDialog).
                button(data_size: "sm", popovertarget: "new-contact") { "add contact" }
              end
              if @rows.empty?
                p(class: "type-body-sm") { @query.empty? ? "No contacts yet." : "No contacts match." }
              else
                ul(class: "card") { @rows.each { render_row(it) } }
              end
            end
            render UpcomingBirthdays.new(upcoming: @upcoming)
          end
          # In the page but out of the columns: a popover opens from
          # wherever it sits, and hidden is its resting state.
          render ContactDialog.new(query: @query)
        end
      end

      private

      # The row's label: "Nickname (Name)" when the card carries a
      # NICKNAME — the name someone is known by, the formal one kept
      # beside it — and the plain name otherwise. The composition is
      # this screen's, not Contact's: the card holds the two facts
      # independently, and other screens (the detail card, the
      # birthdays column) show the plain name.
      #: (Contact contact) -> String
      def label_of(contact)
        nickname = contact.nickname
        name = contact.name
        return "#{nickname} (#{name})" if nickname && name

        nickname || name || contact.id
      end

      # Match generously (docs/DESIGN.md): a contact is findable by
      # name — the nickname too, being the name it lists under — any
      # of its values, or the groups it belongs to.
      #: (Row row, String query) -> bool
      def matches?(row, query)
        q = query.downcase
        return true if row.contact.name&.downcase&.include?(q)
        return true if row.contact.nickname&.downcase&.include?(q)
        return true if row.contact.phones.any? { it.value.downcase.include?(q) }
        return true if row.contact.emails.any? { it.value.downcase.include?(q) }

        false
      end

      #: (Row row) -> void
      def render_row(row)
        li do
          a(href: "/contacts/#{row.contact.id}") do
            render Avatar.new(contact: row.contact, size: "lg")
            div(style: "flex: 1; min-width: 0;") do
              div(style: "font-weight: 550;") { label_of(row.contact) }
            end
            span(class: "type-label") { Format.time_ago(row.updated_at) }
          end
        end
      end
    end
  end
end
