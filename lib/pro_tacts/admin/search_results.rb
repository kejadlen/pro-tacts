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
    # new"). Uncapped, with no "see all" to send a long list to
    # (docs/plans/2026-09-30-live-search.md).
    class SearchResults < Phlex::HTML
      # @rbs @contacts: Array[Store::RecentContact]
      # @rbs @groups: Array[Group]
      # @rbs @recent: bool

      # `recent` is the list standing in for results before there is a
      # query — the most recently updated contacts, labeled as the
      # dashboard labels them (Web#search_results).
      #: (contacts: Array[Store::RecentContact], groups: Array[Group], ?recent: bool) -> void
      def initialize(contacts:, groups:, recent: false)
        @contacts = contacts
        @groups = groups
        @recent = recent
      end

      def view_template
        if @contacts.empty? && @groups.empty?
          p(class: "type-body-sm") { @recent ? "No contacts yet." : "Nothing matches." }
          return
        end

        if @contacts.any?
          h2(class: "type-label") { @recent ? "recently updated" : "contacts" }
          ul(class: "card") { @contacts.each { render RecentRow.new(row: it) } }
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
