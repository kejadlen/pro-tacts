require "pro_tacts/admin/phlex"

require "pro_tacts/admin/layout"
require "pro_tacts/admin/search_field"

module ProTacts
  module Admin
    # GET /search — the search on a phone, where the header's search is
    # a link here rather than the dialog a wider screen opens (Layout;
    # docs/plans/2026-09-30-live-search.md). The same field as the
    # dialog's, in a GET form back to this page: typing narrows the
    # results in place and keeps the address on the query, and without
    # script a submitted query lands here with its results rendered.
    class SearchPage < Phlex::HTML
      # @rbs @login: String
      # @rbs @query: String
      # @rbs @results: Phlex::HTML

      #: (login: String, query: String, results: Phlex::HTML) -> void
      def initialize(login:, query:, results:)
        @login = login
        @query = query
        @results = results
      end

      def view_template
        render Layout.new(title: "Search", login: @login, searching: true) do
          form(action: "/search", method: "get", class: "search-page") do
            render SearchField.new(query: @query, results: @results, history: true)
          end
        end
      end
    end
  end
end
