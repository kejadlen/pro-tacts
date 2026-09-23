require "pro_tacts/admin/phlex"

require "pro_tacts/admin/contact_card"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/record_card"

module ProTacts
  module Admin
    # GET /import/:id/:n for a row the walk has already saved: the
    # contact it became, read beside the card it arrived as
    # (docs/plans/2026-09-21-import-a-vcf.md). A look back, not an
    # editor — the write happened at the row's own Save, and what it
    # wrote is changed where every other contact is, not re-decided
    # inside the walk. The details are ContactCard's, the one renderer
    # of a contact's record, without the groups dialog — membership is
    # the contact page's question (dialog: false, #groups_row's own
    # reason).
    class ImportSaved < Phlex::HTML
      # @rbs @contact: Contact
      # @rbs @groups: Array[Store::Group]
      # @rbs @aside: Phlex::HTML
      # @rbs @sidebar: Phlex::HTML
      # @rbs @edit: String
      # @rbs @notice: String?

      #: (contact: Contact, groups: Array[Store::Group], aside: Phlex::HTML, sidebar: Phlex::HTML, edit: String, ?notice: String?) -> void
      def initialize(contact:, groups:, aside:, sidebar:, edit:, notice: nil)
        @contact = contact
        @groups = groups
        @aside = aside
        @sidebar = sidebar
        @edit = edit
        @notice = notice
      end

      def view_template
        edit = @edit
        render Layout.new(title: @contact.name || @contact.id, wide: true, notice: @notice) do
          render RecordCard.new(
            nav: -> { a(href: edit, class: "btn", data_size: "sm") { "edit" } },
            aside: @aside,
            sidebar: @sidebar,
          ) do
            render ContactCard.new(contact: @contact, groups: @groups, card: false)
          end
        end
      end
    end
  end
end
