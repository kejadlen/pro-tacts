require "pro_tacts/admin/phlex"

require "pro_tacts/admin/contact_card"
require "pro_tacts/admin/group_dialog"
require "pro_tacts/admin/layout"
require "pro_tacts/admin/record_card"

module ProTacts
  module Admin
    # GET /import/:id/:n for a row the walk has already saved: the
    # contact it became, read beside the card it arrived as
    # (docs/plans/2026-09-21-import-a-vcf.md). A look back, not an
    # editor — the write happened at the row's own Save, and later
    # changes are the ones every other contact takes: the editor's
    # amend through the row (#edit_card_screen), and membership
    # through the contact page's own dialog, landed back on the row
    # (`land`) rather than away from the walk. The details are
    # ContactCard's, the one renderer of a contact's record.
    class ImportSaved < Phlex::HTML
      # @rbs @contact: Contact
      # @rbs @groups: Array[Store::Group]
      # @rbs @all_groups: Array[Store::GroupChoice]
      # @rbs @aside: Phlex::HTML
      # @rbs @sidebar: Phlex::HTML
      # @rbs @edit: String
      # @rbs @land: String
      # @rbs @notice: String?

      #: (contact: Contact, groups: Array[Store::Group], all_groups: Array[Store::GroupChoice], aside: Phlex::HTML, sidebar: Phlex::HTML, edit: String, land: String, ?notice: String?) -> void
      def initialize(contact:, groups:, all_groups:, aside:, sidebar:, edit:, land:, notice: nil)
        @contact = contact
        @groups = groups
        @all_groups = all_groups
        @aside = aside
        @sidebar = sidebar
        @edit = edit
        @land = land
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
            render ContactCard.new(contact: @contact, groups: @groups, dialog: true, card: false)
          end
          # The contact page's own dialog over the same card, told to
          # land back on the row: the boxes to check are the groups this
          # contact is in, read off the tags above rather than out of
          # every group's members (ContactsShow's own reason).
          render GroupDialog.new(contact: @contact, groups: @all_groups,
                                 joined: @groups.map(&:id), land: @land)
        end
      end
    end
  end
end
