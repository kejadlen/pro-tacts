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
    # registry, its paths verbatim, this comment's version moved with
    # it.
    class Icon < Phlex::SVG
      # @rbs @name: Symbol
      # @rbs @size: Integer

      # One glyph's path data, verbatim from the lucide-static SVG's
      # own path elements — x, the remove control's two strokes.
      PATHS = {
        x: ["M18 6 6 18", "m6 6 12 12"],
      } #: Hash[Symbol, Array[String]]

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
          PATHS.fetch(@name).each { path(d: it) }
        end
      end
    end
  end
end
