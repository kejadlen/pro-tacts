require "pro_tacts/admin/dashboard"
require "pro_tacts/admin/search"
require "pro_tacts/admin/search_page"
require "pro_tacts/admin/search_results"

module ProTacts
  class Web < Roda
    # The search: the page a phone's header links to, and the results
    # the search field fetches as the query is typed — on that page
    # and in a wider screen's dialog (Admin::SearchField). The match
    # stays in Admin::Search, the one place it is decided, rather than
    # a second copy in the page's script
    # (docs/plans/2026-09-30-live-search.md).
    hash_branch("search") do |r|
      query = r.params["q"].to_s.strip

      r.is do
        r.get do
          response["Content-Type"] = "text/html; charset=utf-8"
          Admin::SearchPage.call(login: @login, query:, results: search_results(query))
        end
      end

      # The results alone, put under the input whole.
      r.get "results" do
        response["Content-Type"] = "text/html; charset=utf-8"
        search_results(query).call
      end
    end

    private

    # A blank query answers the most recently updated contacts, the
    # dashboard's own list, so the search page is never empty before a
    # word is typed.
    #: (String query) -> Admin::SearchResults
    def search_results(query)
      recent = store.contacts_by_recency
      if query.empty?
        return Admin::SearchResults.new(contacts: recent.first(Admin::Dashboard::RECENT_LIMIT), groups: [], recent: true)
      end

      groups = store.all_groups
      Admin::SearchResults.new(
        contacts: Admin::Search.contacts(recent, query:, groups:),
        groups: Admin::Search.groups(groups, query:),
      )
    end
  end
end
