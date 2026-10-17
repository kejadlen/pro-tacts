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
    # Each step is a span (Web#span), and none carries the query.
    hash_branch("search") do |r|
      query = r.params["q"].to_s.strip

      r.is do
        r.get do
          response["Content-Type"] = "text/html; charset=utf-8"
          results = search_results(query)
          span("search.render") { Admin::SearchPage.call(login: @login, query:, results:) }
        end
      end

      # The results alone, put under the input whole.
      r.get "results" do
        response["Content-Type"] = "text/html; charset=utf-8"
        results = search_results(query)
        span("search.render") { results.call }
      end
    end

    private

    # A blank query answers the most recently updated contacts, the
    # dashboard's own list, so the search page is never empty before a
    # word is typed. A query walks every contact's search key and builds
    # only the contacts it finds (docs/plans/2026-10-17-search-keys.md).
    #: (String query) -> Admin::SearchResults
    def search_results(query)
      if query.empty?
        recent = span("search.contacts_by_recency") { |step|
          store.contacts_by_recency(limit: Admin::Dashboard::RECENT_LIMIT).tap { step.set_attribute("rows", it.length) }
        }
        return Admin::SearchResults.new(contacts: recent, groups: [], recent: true)
      end

      keyed = span("search.keyed_by_recency") { |step| store.keyed_by_recency.tap { step.set_attribute("rows", it.length) } }
      groups = span("search.all_groups") { |step| store.all_groups.tap { step.set_attribute("rows", it.length) } }
      ids = span("search.match") { |step|
        Admin::Search.contacts(keyed, query:, groups:).tap {
          step.set_attribute("words", query.split.length)
          step.set_attribute("contacts", it.length)
        }
      }
      contacts = span("search.contacts_by_recency") { |step|
        found = store.contacts_by_recency(ids).to_h {
          [it.contact.id, it] #: [String, Store::RecentContact]
        }
        step.set_attribute("rows", found.length)
        ids.map { found.fetch(it) }
      }
      Admin::SearchResults.new(contacts:, groups: Admin::Search.groups(groups, query:))
    end
  end
end
