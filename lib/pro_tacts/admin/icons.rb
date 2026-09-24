require "pro_tacts/admin/phlex"

module ProTacts
  module Admin
    # Lucide icons, inlined: docs/DESIGN.md's icon register — Lucide
    # at 16–20px, stroke in currentColor, never filled — and this is
    # the set landing there. The path data below is lucide-static's
    # own (v0.548.0, ISC license), copied verbatim rather than redrawn,
    # and inlined rather than served as a file because currentColor
    # cannot cross an <img>: the stroke has to inherit from the
    # element that carries the glyph, Gloss's IconButton included. A
    # new glyph lands the same way this one did — named in the
    # registry, its shapes verbatim, this comment's version moved with
    # it.
    class Icon < Phlex::SVG
      # @rbs @name: Symbol
      # @rbs @size: Integer

      # One glyph's shapes, each an element name and its attributes,
      # verbatim from the lucide-static SVG's own children: x, the
      # remove control's two strokes; calendar, the birthday row's
      # picker; the import row's verdict, a circle either way and
      # a check in it when the row is in the book; and
      # chevron-down, the account menu's opening direction. A tag
      # per shape rather than a bare list of path data, because
      # calendar's frame is a rect and redrawing it as a path would
      # be this file copying something other than what Lucide ships.
      GLYPHS = {
        x: [
          [:path, {d: "M18 6 6 18"}],
          [:path, {d: "m6 6 12 12"}],
        ],
        calendar: [
          [:path, {d: "M8 2v4"}],
          [:path, {d: "M16 2v4"}],
          [:rect, {width: 18, height: 18, x: 3, y: 4, rx: 2}],
          [:path, {d: "M3 10h18"}],
        ],
        circle: [
          [:circle, {cx: 12, cy: 12, r: 10}],
        ],
        circle_check: [
          [:circle, {cx: 12, cy: 12, r: 10}],
          [:path, {d: "m9 12 2 2 4-4"}],
        ],
        chevron_down: [
          [:path, {d: "m6 9 6 6 6-6"}],
        ],
      } #: Hash[Symbol, Array[[Symbol, Hash[Symbol, untyped]]]]

      #: (Symbol name, ?size: Integer) -> void
      def initialize(name, size: 16)
        @name = name
        @size = size
      end

      def view_template
        # viewBox is camelCase on purpose: SVG attribute names are
        # case-sensitive, and Phlex's underscore-to-dash convention
        # would render view_box as view-box, which no browser reads.
        svg(viewBox: "0 0 24 24", width: @size, height: @size, fill: :none,
            stroke: "currentColor", stroke_width: 2, stroke_linecap: "round",
            stroke_linejoin: "round", aria_hidden: true) do
          GLYPHS.fetch(@name).each do |tag, attributes|
            public_send(tag, **attributes)
          end
        end
      end
    end
  end
end
