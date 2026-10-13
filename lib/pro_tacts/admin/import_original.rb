require "pro_tacts/admin/phlex"

require "pro_tacts/import/vcf"

module ProTacts
  module Admin
    # The left-hand card of an import's walk: one contact exactly as
    # the file wrote it (docs/plans/2026-09-21-import-a-vcf.md).
    #
    # Content lines rather than a rendered contact, and in the
    # monospace the bytes are actually in. The card beside this one is
    # the rendered reading — it is the editor, over what is coming in —
    # so a second rendering here would show the same thing twice and
    # answer neither question this card is for: what did the source
    # actually say, and what of it is not coming with it.
    #
    # A line that is not coming in is struck in Gloss's danger color
    # and says so in words beside it (the plan, "The walk"); the
    # blanked editor row wears that color for the same reason
    # (admin.css). Nothing here is a control: what to do about a
    # struck line is done in the editor beside it.
    class ImportOriginal < Phlex::HTML
      # @rbs @card: ::ProTacts::VCard
      # @rbs @dropped: Array[String]

      # `dropped` is the lines that are not coming in (Vcf::Reading),
      # matched here by digest. Two byte-identical lines digest alike
      # and share a fate — the reading is by property name — so there
      # is no pair this cannot tell apart that it would want to.
      #: (card: ::ProTacts::VCard, dropped: Array[::ProTacts::VCard::Parser::Line]) -> void
      def initialize(card:, dropped:)
        @card = card
        @dropped = dropped.map(&:digest)
      end

      def view_template
        div(class: "card") do
          div(class: "card-body") do
            ul(class: "card-lines") do
              @card.lines.each { line(it) }
            end
          end
        end
      end

      private

      # A blank line is not a line to show: it carries no property and
      # says nothing about what the source held.
      #: (::ProTacts::VCard::Parser::Line line) -> void
      def line(line)
        text = ::ProTacts::Import::Vcf.summary(line)
        return if text.strip.empty?

        dropped = @dropped.include?(line.digest)
        li(**(dropped ? {data: {dropped: true}} : {})) do
          span { text }
          span(class: "type-label") { "not imported" } if dropped
        end
      end
    end
  end
end
