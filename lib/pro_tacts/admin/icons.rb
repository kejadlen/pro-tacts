require "pro_tacts/admin/phlex"

module ProTacts
  module Admin
    # Lucide icons, inlined: the set docs/DESIGN.md's icon rule names.
    # The path data below is lucide-static's own (v0.548.0, ISC
    # license), copied verbatim rather than redrawn. A new glyph lands
    # the same way — named in the registry, its shapes verbatim, this
    # comment's version moved with it.
    class Icon < Phlex::SVG
      # @rbs @name: Symbol
      # @rbs @size: Integer

      # One glyph's shapes, each an element name and its attributes,
      # verbatim from the lucide-static SVG's own children: x, the
      # remove and clear controls' two strokes; calendar, the birthday row's
      # picker; the import row's verdict, a circle either way and
      # a check in it when the row is in the book;
      # chevron-down, the account menu's opening direction;
      # search, the glyph on the header's search button; house,
      # the phone header's way home from the search page; image,
      # a group tag's mark that the group has a photo; and trash, an
      # editor row's delete. A tag
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
        search: [
          [:path, {d: "m21 21-4.34-4.34"}],
          [:circle, {cx: 11, cy: 11, r: 8}],
        ],
        image: [
          [:rect, {width: 18, height: 18, x: 3, y: 3, rx: 2, ry: 2}],
          [:circle, {cx: 9, cy: 9, r: 2}],
          [:path, {d: "m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"}],
        ],
        house: [
          [:path, {d: "M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8"}],
          [:path, {d: "M3 10a2 2 0 0 1 .709-1.528l7-6a2 2 0 0 1 2.582 0l7 6A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"}],
        ],
        trash: [
          [:path, {d: "M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"}],
          [:path, {d: "M3 6h18"}],
          [:path, {d: "M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"}],
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
