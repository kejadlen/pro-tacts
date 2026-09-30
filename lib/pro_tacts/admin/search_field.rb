require "json"

require "pro_tacts/admin/phlex"

require "pro_tacts/admin/icons"

module ProTacts
  module Admin
    # The search's input and the results under it, fetched from
    # GET /search/results as it is typed: the one search the header's
    # dialog holds on a wide screen (SearchDialog) and the search page
    # is on a phone (SearchPage). Why the results come from the server
    # rather than a filter in the page is
    # docs/plans/2026-09-30-live-search.md.
    #
    # Alpine does the fetch, waited out until typing pauses and
    # cancelled by the next one, so an answer to an old query never
    # lands over a newer; and the keys, ↑/↓ moving a highlight through
    # the result links and Enter following it, the first by default —
    # while there is a query, the recently updated list the page shows
    # before one being no answer for Enter to pick.
    # Enter with no result to follow submits the form the field sits
    # in, where there is one — the page's, which answers without
    # script too.
    #
    # `query` and `results` are what the field renders holding: the
    # page's own ?q= and its server-rendered answer. `history` keeps
    # the page's address on the query as it changes, so going back to
    # it from a result lands on the same answer; the dialog has no
    # address of its own to keep. `recent` has a blank query fetch
    # the recently updated list too, as the page shows before a word
    # is typed; the dialog opens over a screen showing its own, and
    # clears to nothing.
    class SearchField < Phlex::HTML
      # @rbs @query: String
      # @rbs @results: Phlex::HTML?
      # @rbs @history: bool
      # @rbs @recent: bool

      #: (?query: String, ?results: Phlex::HTML?, ?history: bool, ?recent: bool) -> void
      def initialize(query: "", results: nil, history: false, recent: false)
        @query = query
        @results = results
        @history = history
        @recent = recent
      end

      def view_template
        div(class: "search-field", x_data: state, x_init: "mark()") do
          div(class: "filter") do
            input(type: "search", name: "q", value: @query, placeholder: "Search contacts",
                  aria_label: "Search contacts", autofocus: true, x_model: "q", x_ref: "input",
                  "@input.debounce.150ms": "search()",
                  "@keydown.down.prevent": "move(1)",
                  "@keydown.up.prevent": "move(-1)",
                  "@keydown.enter.prevent": "follow()")
            button(type: "button", class: "icon-button search-clear", data_size: "sm",
                   aria_label: "Clear search", "@click": "q = ''; search(); $refs.input.focus()") do
              render Icon.new(:x)
            end
          end
          div(class: "search-results", x_ref: "results") { render @results if @results }
        end
      end

      private

      # The field's state and the fetch. A failed fetch throws rather
      # than showing a stale or empty list: Alpine surfaces it in the
      # console, and the server has already reported whatever made it
      # fail.
      #: () -> String
      def state
        "{ q: #{JSON.generate(@query)}, history: #{@history}, recent: #{@recent}, active: 0, request: null, " \
          "async search() { this.request?.abort(); this.active = 0; const q = this.q.trim(); " \
          "if (this.history) history.replaceState(null, '', q === '' ? '/search' : '/search?q=' + encodeURIComponent(q)); " \
          "if (q === '' && !this.recent) { this.request = null; this.$refs.results.innerHTML = ''; return } " \
          "const request = this.request = new AbortController(); let html; " \
          "try { const response = await fetch('/search/results?q=' + encodeURIComponent(q), { signal: request.signal }); " \
          "if (!response.ok) throw new Error(`The search failed: the server answered ${response.status}.`); " \
          "html = await response.text() } " \
          "catch (error) { if (error.name === 'AbortError') return; throw error } " \
          "if (request !== this.request) return; " \
          "this.$refs.results.innerHTML = html; this.mark() }, " \
          "get links() { return [...this.$refs.results.querySelectorAll('a')] }, " \
          "move(step) { const n = this.links.length; if (n === 0) return; " \
          "this.active = (this.active + step + n) % n; this.mark() }, " \
          "mark() { const on = this.q.trim() !== ''; " \
          "this.links.forEach((link, i) => link.toggleAttribute('data-active', on && i === this.active)); " \
          "this.links[this.active]?.scrollIntoView({ block: 'nearest' }) }, " \
          "follow() { const link = this.q.trim() === '' ? null : this.links[this.active]; " \
          "if (link) link.click(); else this.$el.closest('form')?.requestSubmit() } }"
      end
    end
  end
end
