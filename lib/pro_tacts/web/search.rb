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
    #
    # Each step is a span on the request's Sentry transaction, so a slow
    # search names its slow step. A span carries counts and never the
    # query, which is a name typed into a field.
    hash_branch("search") do |r|
      query = r.params["q"].to_s.strip

      r.is do
        r.get do
          response["Content-Type"] = "text/html; charset=utf-8"
          results = search_results(query)
          search_span("render") { Admin::SearchPage.call(login: @login, query:, results:) }
        end
      end

      # The results alone, put under the input whole.
      r.get "results" do
        response["Content-Type"] = "text/html; charset=utf-8"
        results = search_results(query)
        search_span("render") { results.call }
      end
    end

    private

    # A blank query answers the most recently updated contacts, the
    # dashboard's own list, so the search page is never empty before a
    # word is typed.
    #: (String query) -> Admin::SearchResults
    def search_results(query)
      recent = search_span("contacts_by_recency") { |span|
        store.contacts_by_recency.tap { span&.set_data("rows", it.length) }
      }
      if query.empty?
        return Admin::SearchResults.new(contacts: recent.first(Admin::Dashboard::RECENT_LIMIT), groups: [], recent: true)
      end

      groups = search_span("all_groups") { |span| store.all_groups.tap { span&.set_data("rows", it.length) } }
      search_span("match") { |span|
        contacts = Admin::Search.contacts(recent, query:, groups:)
        span&.set_data("words", query.split.length)
        span&.set_data("contacts", contacts.length)
        Admin::SearchResults.new(contacts:, groups: Admin::Search.groups(groups, query:))
      }
    end

    #: [T] (String step) { (Sentry::Span?) -> T } -> T
    def search_span(step, &)
      Sentry.with_child_span(op: "search.#{step}", description: step, &)
    end
  end
end
