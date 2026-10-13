require "pro_tacts/admin/phlex"

require "pro_tacts/admin/format"
require "pro_tacts/admin/icons"

module ProTacts
  module Admin
    # The contacts an uploaded .vcf holds, down the side of every
    # screen of the import. Why a sidebar, and the two facts each row
    # carries — the verdict at its trailing edge, the count of lines
    # the card is losing under its name — are
    # docs/plans/2026-09-21-import-a-vcf.md, "The list is a sidebar".
    # The verdict's word stays for a screen reader
    # (.gl-visually-hidden); the count wears a change log entry's mark
    # (Admin::ContactsShow#diff_lines, .diff-removed in admin.css).
    class ImportSidebar < Phlex::HTML
      # @rbs @upload: String
      # @rbs @rows: Array[[::ProTacts::Contact, Integer, Integer]]
      # @rbs @saved: Hash[String, String]
      # @rbs @current: Integer?

      # `rows` is the contact each card will be written as, how many
      # of its original's lines are not coming with it, and the card's
      # place in the file, in the order the list reads
      # (Web#walk_order); `saved` the contact each row that has come in
      # was written as, by the row's place in the file; `current` the
      # row whose screen is open.
      #: (upload: String, rows: Array[[::ProTacts::Contact, Integer, Integer]], saved: Hash[String, String], current: Integer) -> void
      def initialize(upload:, rows:, saved:, current:)
        @upload = upload
        @rows = rows
        @saved = saved
        @current = current
      end

      # The record's own column shape (.record in admin.css), with no
      # caption row (the plan, "The list is a sidebar").
      def view_template
        nav(class: "record walk-list") do
          ul(class: "card") do
            @rows.each do |(contact, dropped, index)|
              row(contact, dropped, index)
            end
          end
        end
      end

      private

      #: (::ProTacts::Contact contact, Integer dropped, Integer index) -> void
      def row(contact, dropped, index)
        stored = @saved[index.to_s]
        li do
          # Every row opens in the walk, a saved one included, as the
          # contact it became beside the card it arrived as
          # (Web#card_screen; the plan, "Nothing waits for the end").
          # `aria-current` marks the row being read, the one thing a
          # list beside its own content has to say that a list on a
          # page of its own does not.
          a(href: "/import/#{@upload}/#{index}",
            aria_current: ("page" if index == @current),
            data: {state: stored ? "saved" : "unsaved"}) do
            div(style: "flex: 1; min-width: 0;") do
              div(style: "font-weight: 550;") { Format.name_label(contact) }
              unless stored
                span(class: "type-label diff-removed") { "-#{dropped}" } if dropped.positive?
              end
            end
            span(class: "gl-visually-hidden") { stored ? "saved" : "not saved" }
            render Icon.new(stored ? :circle_check : :circle)
          end
        end
      end
    end
  end
end
