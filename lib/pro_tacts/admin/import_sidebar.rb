require "pro_tacts/admin/phlex"

require "pro_tacts/admin/format"
require "pro_tacts/admin/icons"

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
    # contact is in the book — the verdict at the row's trailing
    # edge, a circle either way with the check landed in it when the
    # row is: the success color, confirmed being that color's one
    # meaning (docs/DESIGN.md), and the name a step quieter with it,
    # a done thing receding so the rows still to do carry the walk's
    # own ink. Everything here is unsaved until its own screen says
    # otherwise, and a walk broken off overnight has to say which
    # rows those are. Words for it were the first try and were too
    # much: "not saved" on every row of a list that starts out
    # entirely unsaved is a column of the same sentence, and it took
    # the one slot the row's other fact wants. The word is still
    # there for a screen reader, which cannot see a mark
    # (.gl-visually-hidden).
    #
    # And what the card is losing, as a diff's own mark under the
    # name it is about — `-3` on a row still to do, in the
    # sign-and-color shape a change log entry wears
    # (Admin::ContactsShow#diff_lines, .diff-removed in admin.css) —
    # because the number is the whole of what a row has to say about
    # it and a sentence for it made every marked row a line of
    # prose.
    class ImportSidebar < Phlex::HTML
      # @rbs @upload: String
      # @rbs @rows: Array[[::ProTacts::Contact, Integer, Integer]]
      # @rbs @saved: Hash[String, String]
      # @rbs @current: Integer?

      # `rows` is the contact each card will be written as, how many
      # of its original's lines are not coming with it, and the card's
      # place in the file, in the order the list reads
      # (Web#walk_order); `saved`
      # the contact each row that has come in was written as, by the
      # row's place in the file; `current` the row whose screen is
      # open.
      #: (upload: String, rows: Array[[::ProTacts::Contact, Integer, Integer]], saved: Hash[String, String], current: Integer) -> void
      def initialize(upload:, rows:, saved:, current:)
        @upload = upload
        @rows = rows
        @saved = saved
        @current = current
      end

      # The record's own column shape (.record in admin.css), the
      # thing beside it being a record too — but no caption row: the
      # rows are self-evidently contacts, and the screen about the
      # file they came from is gone, so there is nothing for a
      # caption over the list to name or reach. What sits over the
      # editor is its own action's row and nothing else.
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
          # Every row opens in the walk, a saved one included: the
          # card was written the moment its Save was pressed, and its
          # row opens it as the contact it became beside the card it
          # arrived as — rather than navigating away from the list to
          # the contact's own page (Web#open_card). `aria-current`
          # marks the row being read, which is the one thing a list
          # beside its own content has to say that a list on a page
          # of its own does not.
          a(href: "/import/#{@upload}/#{index}",
            aria_current: ("page" if index == @current),
            data: {state: stored ? "saved" : "unsaved"}) do
            div(style: "flex: 1; min-width: 0;") do
              div(style: "font-weight: 550;") { Format.name_label(contact) }
              # What the card is losing, under the name it is about
              # and only while there is a save to decide about: a
              # settled row's losses are settled with it.
              unless stored
                span(class: "type-label diff-removed") { "-#{dropped}" } if dropped.positive?
              end
            end
            span(class: "gl-visually-hidden") { stored ? "saved" : "not saved" }
            # The trailing edge is the row's verdict: the circle for
            # a row not in the book, the check landed in it when the
            # row is.
            render Icon.new(stored ? :circle_check : :circle)
          end
        end
      end
    end
  end
end
