require "pro_tacts/admin/phlex"

require "pro_tacts/admin/format"

module ProTacts
  module Admin
    # The contacts an uploaded .vcf holds, down the side of every
    # screen of the import (docs/plans/2026-09-21-import-a-vcf.md).
    #
    # Beside the content rather than a page of its own, because the
    # walk is a list worked down: opening a row used to mean leaving
    # the list, looking at one card, and coming back to find your
    # place in it again. Here the place is never lost — the row being
    # read is marked, the row after it is the next thing to click, and
    # what the last ten screens settled is in view while the eleventh
    # is open.
    #
    # Each row carries the two facts the walk turns on. Whether the
    # contact is in the book — a rail in the accent down the inside
    # edge of every row that is not, because everything here is
    # unsaved until its own screen says otherwise and a walk broken
    # off overnight has to say which rows those are. Words for it were
    # the first try and were too much: "not saved" on every row of a
    # list that starts out entirely unsaved is a column of the same
    # sentence, and it took the one slot the row's other fact wants.
    # The word is still there for a screen reader, which cannot see a
    # rail (.gl-visually-hidden).
    #
    # And what the card is losing, as a diff's own mark — `-3` at the
    # row's trailing edge, in the sign-and-color shape a change log
    # entry wears (Admin::ContactsShow#diff_lines, .diff-removed in
    # admin.css) — because the number is the whole of what a row has
    # to say about it and a sentence for it made every marked row a
    # line of prose.
    class ImportSidebar < Phlex::HTML
      # @rbs @upload: String
      # @rbs @rows: Array[[::ProTacts::Contact, Integer]]
      # @rbs @saved: Hash[String, String]
      # @rbs @current: Integer?

      # `rows` is the contact each card will be written as and how
      # many of its original's lines are not coming with it; `saved`
      # the contact each row that has come in was written as, by the
      # row's place in the file; `current` the row whose screen is
      # open, or none on the screen that is about the file itself.
      #: (upload: String, rows: Array[[::ProTacts::Contact, Integer]], saved: Hash[String, String], ?current: Integer?) -> void
      def initialize(upload:, rows:, saved:, current: nil)
        @upload = upload
        @rows = rows
        @saved = saved
        @current = current
      end

      # A record's own shape — caption row over card — because the
      # thing beside this is one too, and two columns whose cards
      # start at different heights read as a mistake before they read
      # as anything else (.record in admin.css). The caption is the
      # way back to what the file as a whole is losing, that screen
      # having no row of its own to be reached from.
      def view_template
        nav(class: "record walk-list") do
          div(class: "record-nav") do
            a(href: "/import/#{@upload}", class: "type-label") { "contacts" }
          end
          ul(class: "card") do
            @rows.each_with_index do |(contact, dropped), index|
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
          # A row that has come in leads to the contact it became: the
          # card was written the moment its Save was pressed, and from
          # then on it is edited where every other contact is
          # (Web#open_card). `aria-current` marks the row being read,
          # which is the one thing a list beside its own content has
          # to say that a list on a page of its own does not.
          a(href: stored ? "/contacts/#{stored}" : "/import/#{@upload}/#{index}",
            aria_current: ("page" if index == @current),
            data: {state: stored ? "saved" : "unsaved"}) do
            div(style: "flex: 1; min-width: 0; font-weight: 550;") { Format.name_label(contact) }
            span(class: "gl-visually-hidden") { stored ? "saved" : "not saved" }
            span(class: "type-label diff-removed") { "-#{dropped}" } if dropped.positive?
          end
        end
      end
    end
  end
end
