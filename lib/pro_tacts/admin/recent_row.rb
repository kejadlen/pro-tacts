require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/format"
require "pro_tacts/admin/list_item"

module ProTacts
  module Admin
    # A contact's row where the list is one of recency — the
    # dashboard's recently updated and the search's results, which
    # keep recency within each rank (Search.contacts) — so the row
    # says how long ago the card changed.
    class RecentRow < Phlex::HTML
      # @rbs @row: Store::RecentContact

      #: (row: Store::RecentContact) -> void
      def initialize(row:)
        @row = row
      end

      def view_template
        render ListItem.new(
          href: "/contacts/#{@row.contact.id}",
          avatar: Avatar.new(contact: @row.contact, size: "lg"),
          trailing: Format.time_ago(@row.updated_at),
        ) { Format.name_label(@row.contact) }
      end
    end
  end
end
