require "pro_tacts/admin/phlex"

require "pro_tacts"

module ProTacts
  module Admin
    # The one page shell every admin screen renders inside: head, the
    # vendored Gloss stylesheets (see public/vendor/gloss and
    # docs/DESIGN.md), and a one-line header naming the app in type —
    # "no brand mark" is one of the rules that document inherits from
    # Gloss — with the collection search beside the name on every
    # screen: a header that grew and shrank with the search made the
    # chrome jump between pages, and search-first (docs/DESIGN.md)
    # wants finding a contact possible from anywhere. `query` carries
    # the dashboard's current search into the input's value;
    # `autofocus` is a screen saying its entry point is the search —
    # the dashboard with an empty query, the one place the design
    # doc wants "focused and ready". `wide` opts a screen out of the
    # reading width a single column wants (see admin.css) — the
    # dashboard root is the one screen that asks.
    #
    # Alpine loads on every screen, and it is the only script here.
    # The admin UI was script-free until the edit screen needed to
    # add a row to a form without a round trip: CSS can reveal a
    # fixed set of elements but cannot make one, so every version of
    # that built out of `:has()` and hidden inputs traded a real
    # affordance away — a cap on how many, or a field that stayed
    # behind after it was used. Alpine is the smallest thing that
    # buys back the missing verb. Where markup alone still does the
    # job it keeps doing it: the popovers open and close by the
    # Popover API, not by script.
    class Layout < Phlex::HTML
      #: (title: String, ?wide: bool, ?query: String?, ?autofocus: bool, ?notice: String?) -> void
      def initialize(title:, wide: false, query: nil, autofocus: false, notice: nil)
        @title = title
        @wide = wide
        @query = query
        @autofocus = autofocus
        @notice = notice
      end

      def view_template
        doctype
        html(lang: "en") do
          head do
            meta(charset: "utf-8")
            meta(name: "viewport", content: "width=device-width, initial-scale=1")
            title { "pro-tacts — #{@title}" }
            # No webfont. --gl-font-mono names IBM Plex Mono first and
            # falls back through ui-monospace to the platform's own
            # (tokens.css), so a face this app does not ship is a
            # preference the browser honors when the reader happens to
            # have it, not a download. What was here before was a
            # remote Google Fonts stylesheet, and the self-hosted
            # woff2s meant to replace it were never added — the
            # @font-face rules pointed at three files that 404ed.
            link(rel: "stylesheet", href: "/vendor/gloss/tokens.css")
            link(rel: "stylesheet", href: "/vendor/gloss/base.css")
            link(rel: "stylesheet", href: "/vendor/gloss/components.css")
            link(rel: "stylesheet", href: "/admin.css")
            # Alpine, vendored and pinned (rake alpine:vendor) rather
            # than pulled from a CDN, for the reason the Gloss CSS is:
            # this app is reachable only over Tailscale and should not
            # need anything else reachable to render. `defer` is
            # Alpine's own requirement — it initializes on
            # DOMContentLoaded and must not run before the markup it
            # reads exists.
            script(defer: true, src: "/vendor/alpine/alpine.min.js")
          end
          body do
            header(class: "admin-header") do
              # The groups list rides beside the name because it is
              # where a group is created, and creating one is a thing
              # to reach from anywhere; search still finds one by name.
              nav do
                a(href: "/") { "pro-tacts" }
                a(href: "/groups") { "groups" }
              end
              # Every screen's chrome, not the dashboard's alone: the
              # input keeps the query it carries — a results page has
              # somewhere to be besides the input — and focuses only
              # where the screen asked for it.
              form(action: "/", method: "get", class: "search-form") do
                input(type: "search", name: "q", value: @query,
                      placeholder: "Search contacts", autofocus: @autofocus)
              end
            end
            main(class: "admin-main", **(@wide ? {data: {wide: true}} : {})) { yield }
            # The shell's other edge: which build is answering, whether
            # it is logging what it answers, and the one screen search
            # cannot reach. All of it read off the environment (see
            # Config) rather than passed down through every screen's
            # call — these are the shell's own facts, the same on all
            # of them.
            #
            # The version is the image's tag and the release's name at
            # once, so it stands alone: the commit and the build time
            # are spelled inside it, and a second label repeating either
            # would be the same fact twice. Nothing built by the release
            # job carries one, and that absence is its own fact worth
            # stating — a screen that looks like the deployment but
            # answers out of a working copy is exactly the confusion the
            # footer exists to end.
            #
            # Debug logging says so while it is on because it dumps
            # whole requests, contact data included (see DebugLogger),
            # and a log left recording is the kind of thing found months
            # later. Off, the label is absent: the footer states what is
            # true, and the quiet case is the normal one. It reads as a
            # flag on the version rather than a sentence beside it —
            # "+debug" is a build with something switched on, which is
            # what it is, and the plus is its own separator.
            #
            # Device setup belongs here because the dashboard is a
            # search over contacts and /setup is not a contact — a
            # header link would put it beside the search on every
            # screen, at the weight the app's own name has.
            footer(class: "admin-footer") do
              span(class: "type-label") { ProTacts.config.version || "dev server" }
              span(class: "type-label") { "+debug" } if ProTacts.config.debug?
              a(href: "/setup", class: "type-label") { "device setup" }
            end
            # A server-rendered toast, Gloss's [role=status] contract:
            # the one line a refused write leaves behind, fixed to the
            # corner until the next navigation carries it off — no
            # dismiss control, because with no script there is nothing
            # to dismiss it with, and "leave" is the design doc's own
            # word for what a toast does next.
            if @notice
              div(role: "status", data: {fixed: true}) { span { @notice } }
            end
          end
        end
      end
    end
  end
end
