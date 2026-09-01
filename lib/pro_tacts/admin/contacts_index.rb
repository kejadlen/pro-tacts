require "phlex"

require "pro_tacts/admin/format"
require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # GET / — search first, no browsing (docs/DESIGN.md): a query
    # narrows to matches across every contact, an empty query shows
    # the ten most recently updated. Read-only: no add, no edit,
    # nothing to commit, so there is no state here beyond the query.
    class ContactsIndex < Phlex::HTML
      RECENT_LIMIT = 10

      Row = Data.define(:contact, :updated_at)
      private_constant :Row

      #: (recent: Array[Store::RecentContact], query: String?) -> void
      def initialize(recent:, query:)
        @query = query.to_s.strip
        rows = recent.map { Row.new(contact: it.contact, updated_at: it.updated_at) }
        @rows = @query.empty? ? rows.first(RECENT_LIMIT) : rows.select { matches?(it, @query) }
      end

      def view_template
        render Layout.new(title: "Contacts") do
          h1(class: "type-h1") { "Contacts" }
          form(action: "/", method: "get", class: "search-form") do
            input(type: "search", name: "q", value: @query, placeholder: "Search contacts", autofocus: @query.empty?)
          end
          span(class: "type-label") { @query.empty? ? "recently updated" : "results" }
          if @rows.empty?
            p(class: "type-body-sm") { @query.empty? ? "No contacts yet." : "No contacts match." }
          else
            ul(class: "card") { @rows.each { render_row(it) } }
          end
        end
      end

      private

      #: (Row row, String query) -> bool
      def matches?(row, query)
        q = query.downcase
        return true if row.contact.name&.downcase&.include?(q)
        return true if row.contact.phones.any? { it.value.downcase.include?(q) }
        return true if row.contact.emails.any? { it.value.downcase.include?(q) }

        false
      end

      #: (Row row) -> void
      def render_row(row)
        li do
          a(href: "/contacts/#{row.contact.id}") do
            span(class: "avatar") { Format.initials(row.contact) }
            div(style: "flex: 1; min-width: 0;") do
              div(style: "font-weight: 550;") { row.contact.name || row.contact.id }
            end
            span(class: "type-label") { Format.time_ago(row.updated_at) }
          end
        end
      end
    end
  end
end
