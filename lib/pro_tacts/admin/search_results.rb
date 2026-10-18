require "pro_tacts/admin/phlex"

require "pro_tacts/admin/group_label"
require "pro_tacts/admin/list_item"
require "pro_tacts/admin/recent_row"

module ProTacts
  module Admin
    # The list under the search's input (SearchField), which
    # GET /search/results answers alone and the search page renders
    # in: the contacts a query matches in the order Search ranks them
    # and then the groups — a group is a record the search reaches as
    # surely as a contact is (docs/DESIGN.md, "When adding something
    # new"). The contacts stop at LIMIT, and the rest are counted
    # rather than listed: the answer to a query that long is a longer
    # query (docs/plans/2026-10-17-search-keys.md).
    class SearchResults < Phlex::HTML
      LIMIT = 50 #: Integer

      # @rbs @contacts: Array[Store::RecentContact]
      # @rbs @groups: Array[Group]
      # @rbs @recent: bool
      # @rbs @more: Integer

      # `recent` is the list standing in for results before there is a
      # query — the most recently updated contacts, labeled as the
      # dashboard labels them (Web#search_results).
      # `more` is how many matched past LIMIT.
      #: (contacts: Array[Store::RecentContact], groups: Array[Group], ?recent: bool, ?more: Integer) -> void
      def initialize(contacts:, groups:, recent: false, more: 0)
        @contacts = contacts
        @groups = groups
        @recent = recent
        @more = more
      end

      def view_template
        if @contacts.empty? && @groups.empty?
          p(class: "type-body-sm") { @recent ? "No contacts yet." : "Nothing matches." }
          return
        end

        if @contacts.any?
          h2(class: "type-label") { @recent ? "recently updated" : "contacts" }
          ul(class: "card") { @contacts.each { render RecentRow.new(row: it) } }
          p(class: "type-body-sm") { "#{@more} more. Keep typing to narrow them down." } if @more.positive?
        end
        return if @groups.empty?

        h2(class: "type-label") { "groups" }
        ul(class: "card") do
          @groups.each do |group|
            render ListItem.new(href: "/groups/#{group.id}") { render GroupLabel.new(group:) }
          end
        end
      end
    end
  end
end
