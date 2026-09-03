require "phlex"

module ProTacts
  module Admin
    # The one page shell every admin screen renders inside: head, the
    # vendored Gloss stylesheets (see public/vendor/gloss and
    # docs/DESIGN.md), and a one-line header naming the app in type —
    # "no brand mark" is one of the rules that document inherits from
    # Gloss. `wide` opts a screen out of the reading width a single
    # column wants (see admin.css) — the dashboard root is the one
    # screen that asks. No JavaScript: nothing served here yet needs
    # any.
    class Layout < Phlex::HTML
      #: (title: String, ?wide: bool) -> void
      def initialize(title:, wide: false)
        @title = title
        @wide = wide
      end

      def view_template
        doctype
        html(lang: "en") do
          head do
            meta(charset: "utf-8")
            meta(name: "viewport", content: "width=device-width, initial-scale=1")
            title { "pro-tacts — #{@title}" }
            link(rel: "preconnect", href: "https://fonts.googleapis.com")
            link(rel: "stylesheet", href: "https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&display=swap")
            link(rel: "stylesheet", href: "/vendor/gloss/tokens.css")
            link(rel: "stylesheet", href: "/vendor/gloss/base.css")
            link(rel: "stylesheet", href: "/vendor/gloss/components.css")
            link(rel: "stylesheet", href: "/admin.css")
          end
          body do
            header(class: "admin-header") { a(href: "/") { "pro-tacts" } }
            main(class: "admin-main", **(@wide ? {data: {wide: true}} : {})) { yield }
          end
        end
      end
    end
  end
end
