require "pro_tacts/admin/phlex"

module ProTacts
  module Admin
    # One row of a card list: an li holding a link, an optional avatar
    # in front, the block's label in a bold column that flexes, and an
    # optional muted label behind it — the row shape every browse
    # screen shares (the dashboard's contacts and group results,
    # /contacts, /groups). The middle column is the one piece of
    # layout this owns: min-width 0 lets a long name shrink instead
    # of pushing what trails it off the card.
    class ListItem < Phlex::HTML
      # @rbs @href: String
      # @rbs @avatar: Phlex::HTML?
      # @rbs @trailing: String?

      #: (href: String, ?avatar: Phlex::HTML?, ?trailing: String?) -> void
      def initialize(href:, avatar: nil, trailing: nil)
        @href = href
        @avatar = avatar
        @trailing = trailing
      end

      def view_template
        li do
          a(href: @href) do
            render @avatar if @avatar
            div(style: "flex: 1; min-width: 0; font-weight: 550;") { yield }
            span(class: "type-label") { @trailing } if @trailing
          end
        end
      end
    end
  end
end
