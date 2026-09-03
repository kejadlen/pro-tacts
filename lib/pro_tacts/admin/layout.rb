require "pro_tacts/admin/phlex"

module ProTacts
  module Admin
    # The one page shell every admin screen renders inside: head, the
    # vendored Gloss stylesheets (see public/vendor/gloss and
    # docs/DESIGN.md), and a one-line header naming the app in type —
    # "no brand mark" is one of the rules that document inherits from
    # Gloss. A screen that passes `search` renders the collection
    # search in that header, beside the name (docs/DESIGN.md's
    # search-first rule). `wide` opts a screen out of the reading
    # width a single column wants (see admin.css) — the dashboard
    # root is the one screen that asks. No JavaScript: nothing served
    # here yet needs any.
    class Layout < Phlex::HTML
      #: (title: String, ?wide: bool, ?search: String?) -> void
      def initialize(title:, wide: false, search: nil)
        @title = title
        @wide = wide
        @search = search
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
            header(class: "admin-header") do
              a(href: "/") { "pro-tacts" }
              # The dashboard's query follows the search into the
              # header: the input keeps its value across a search, and
              # focuses only when the query is empty — a results page
              # has somewhere to be besides the input.
              if @search
                form(action: "/", method: "get", class: "search-form") do
                  input(type: "search", name: "q", value: @search,
                        placeholder: "Search contacts", autofocus: @search.to_s.empty?)
                end
              end
            end
            main(class: "admin-main", **(@wide ? {data: {wide: true}} : {})) { yield }
          end
        end
      end
    end
  end
end
