require "pro_tacts/admin/phlex"

require "pro_tacts"
require "pro_tacts/admin/icons"

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
      # The account menu's popover, opened by the button that names
      # the login.
      MENU = "user-menu" #: String
      private_constant :MENU

      # @rbs @title: String
      # @rbs @login: String
      # @rbs @wide: bool
      # @rbs @query: String?
      # @rbs @autofocus: bool
      # @rbs @notice: String?

      #: (title: String, login: String, ?wide: bool, ?query: String?, ?autofocus: bool, ?notice: String?) -> void
      def initialize(title:, login:, wide: false, query: nil, autofocus: false, notice: nil)
        @title = title
        @login = login
        @wide = wide
        @query = query
        @autofocus = autofocus
        @notice = notice
      end

      def view_template
        doctype
        # A configured accent marks the root, and admin.css repaints the
        # accent and the chrome for it: `rake dev` names one so a working
        # copy cannot pass for the deployment at a glance (docs/DESIGN.md).
        accent = ProTacts.config.accent
        html(lang: "en", **(accent ? {data: {accent:}} : {})) do
          head do
            meta(charset: "utf-8")
            meta(name: "viewport", content: "width=device-width, initial-scale=1")
            # The instance's name, so a tab says which server it is
            # (`rake dev` names its own).
            title { "#{ProTacts.config.instance_name} — #{@title}" }
            favicon = ProTacts.config.favicon
            link(rel: "icon", href: favicon) if favicon
            # No webfont (docs/DESIGN.md), so there is no font link
            # among these. What was here before was a remote Google
            # Fonts stylesheet, and the self-hosted woff2s meant to
            # replace it were never added — the @font-face rules
            # pointed at three files that 404ed.
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
              # The name and, beside it, the one control every screen
              # shares: what this app is and how it is asked a
              # question, on the left where reading starts. The input
              # keeps the query it carries — a results page has
              # somewhere to be besides the input — and focuses only
              # where the screen asked for it.
              a(href: "/") { "pro-tacts" }
              # The search and, in the field's end, its clear: a link,
              # because clearing the dashboard's search is navigating
              # to the page with no query — the form's own target with
              # nothing submitted — landing focused on an empty input
              # again. CSS reveals it the moment there is text to clear
              # (admin.css), typed-but-unsubmitted included, so the
              # header needs no script for it; the native cancel WebKit
              # and Blink draw is suppressed there too, one affordance
              # rather than two.
              #
              # On a phone the search folds into its glyph and opens
              # across the whole header while it has focus or a query
              # (admin.css). The label is what makes the glyph open
              # it: a tap anywhere in a label focuses its field, so
              # the fold needs no script either.
              form(action: "/", method: "get", class: "search-form") do
                label do
                  render Icon.new(:search)
                  input(type: "search", name: "q", value: @query,
                        placeholder: "Search contacts", autofocus: @autofocus)
                end
                a(href: "/", class: "icon-button search-clear", data_size: "sm",
                  aria_label: "Clear search") { render Icon.new(:x) }
              end
              # The destinations and the account, at the right edge:
              # the contacts list is the browse surface and the groups
              # list is where a group is created — both reachable from
              # anywhere (docs/DESIGN.md, "The core idea"), search
              # still finding a group by name — with who is asking
              # named beside them. On a phone the two move into the
              # account menu with home, the name's own link (the list
              # below repeats all three for that), leaving the header
              # the search and the account.
              nav do
                a(href: "/contacts") { "contacts" }
                a(href: "/groups") { "groups" }
              end
              # The account the proxy vouches for (ProxyAuth), named
              # where the session reads as belonging to someone. The
              # button opens a menu rather than a page because the
              # account has no page: a login decides which cards sync
              # to whose devices (docs/plans/2026-09-12-per-user-
              # books.md) and nothing else, so what hangs off it is
              # the destinations that are not records and so
              # cannot be searched for — import, a handful of times in
              # a book's life (docs/plans/2026-09-21-import-a-vcf.md),
              # export, its counterpart, and device setup. A popover
              # by the Popover API, like
              # every floated layer here; the list sits beside its
              # button in the header because a promoted popover is
              # positioned against the viewport, not the DOM beside
              # its button, so admin.css anchors it to the wrapper by
              # name — while the Popover API still renders it above
              # everything when open.
              div(class: "user-menu") do
                button(type: "button", data_size: "sm", popovertarget: MENU) do
                  span { @login }
                  render Icon.new(:chevron_down)
                end
                ul(id: MENU, popover: "auto", class: "user-menu-list") do
                  li(class: "menu-nav") { a(href: "/") { "home" } }
                  li(class: "menu-nav") { a(href: "/contacts") { "contacts" } }
                  li(class: "menu-nav") { a(href: "/groups") { "groups" } }
                  li { a(href: "/import") { "import" } }
                  li { a(href: "/contacts/export.vcf") { "export" } }
                  li { a(href: "/setup") { "device setup" } }
                end
              end
            end
            main(class: "admin-main", **(@wide ? {data: {wide: true}} : {})) { yield }
            # The shell's other edge: which build is answering and
            # whether it is logging what it answers, both read off
            # the environment (see Config) rather than passed down
            # through every screen's call — these are the shell's own
            # facts, the same on all of them.
            #
            # The version is the image's tag and the release's name at
            # once, so it stands alone: the commit and the build time
            # are spelled inside it, and a second label repeating either
            # would be the same fact twice. `rake dev` stamps the jj
            # change it runs from instead; a run with neither says
            # nothing rather than guessing what it is. Centered, with
            # nothing else in the footer: the frame's other edge is
            # the build's own label, and a build with no label still
            # draws the edge.
            #
            # Debug logging says so while it is on because it dumps
            # every sync whole, contact data included (see ExchangeLog),
            # and a log left recording is the kind of thing found months
            # later. Off, the label is absent: the footer states what is
            # true, and the quiet case is the normal one. It reads as a
            # flag on the version rather than a sentence beside it —
            # "+debug" is a build with something switched on, which is
            # what it is, and the plus is its own separator.
            footer(class: "admin-footer") do
              version = ProTacts.config.version
              span(class: "type-label") { version } if version
              span(class: "type-label") { "+debug" } if ProTacts.config.debug?
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
