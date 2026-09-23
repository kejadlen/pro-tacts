require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/format"
require "pro_tacts/admin/group_dialog"
require "pro_tacts/admin/group_label"

module ProTacts
  module Admin
    # A contact's details as a card: the header its rows sit under and
    # the rows themselves, every row's type in one column and its
    # value in the other (docs/DESIGN.md, "Alignment is the layout"),
    # and an attribute with no data getting no row at all.
    #
    # The contact's own page (ContactsShow) renders it inside its
    # record, and an import's saved row renders it beside the card
    # that row arrived as (ImportSaved) — one renderer, so a property
    # one screen shows is a property the other cannot drop.
    #
    # `groups` is the contact's membership (Store#groups_of), the row
    # framing the values under it. `dialog` names whether that row
    # carries its "edit groups" button, which needs GroupDialog on the
    # page: the contact's page and a walk's saved row both render it,
    # each telling the save where to land. `card` names
    # whether this renders the card around its own body or the body
    # alone for a card someone else supplies — the walk's read screen
    # (ImportSaved), whose trunk RecordCard owns.
    class ContactCard < Phlex::HTML
      # @rbs @contact: Contact
      # @rbs @groups: Array[Store::Group]
      # @rbs @dialog: bool
      # @rbs @card: bool

      #: (contact: Contact, groups: Array[Store::Group], ?dialog: bool, ?card: bool) -> void
      def initialize(contact:, groups:, dialog: false, card: true)
        @contact = contact
        @groups = groups
        @dialog = dialog
        @card = card
        @birthday = Format.birthday(contact)
      end

      def view_template
        return body unless @card

        div(class: "card") do
          div(class: "card-body") do
            body
          end
        end
      end

      #: () -> void
      def body
        div(class: "detail-header") do
          div do
            h1(class: "type-h2") { @contact.name || @contact.id }
            # The nickname rides under the name in the heading
            # family — type-h3 to the name's h2 — so it reads as
            # a name rather than a property value; muted, so the
            # formal name stays the heading.
            if @contact.nickname
              div(class: "type-h3 gl-muted", style: "margin-top: var(--gl-space-2xs);") { @contact.nickname }
            end
          end
          # Only a picture earns this slot: an initials circle
          # beside the name in type-h2 would repeat what the name
          # already says. The dashboard rows keep theirs — there
          # the avatar is the row's visual anchor, not a caption.
          render Avatar.new(contact: @contact, size: "xl") if @contact.photo
        end
        # The grid holds what the contact has and nothing it does
        # not — a groupless contact on a walk screen has no groups
        # row, there being no member to name and no dialog to
        # open (#groups_row's own reason).
        dl(class: "detail-grid") { rows }
      end

      private

      # A missing TYPE parameter still gets a key: the fallback names
      # the kind of value, so no row renders unlabeled in the grid.
      # Every row that reads from a line hands it over, because which
      # group lends a row is a question about the line it came from.
      # The birthday hands over none: it is the model beside the card,
      # and a group holds only addresses and notes anyway (see
      # db/migrations/004_groups.rb).
      def rows
        groups_row if @dialog || @groups.any?
        @contact.phones.each do |phone|
          row(Format.type_label(phone.label, phone.types, "phone"), phone.value, phone.line)
        end
        @contact.emails.each do |email|
          row(Format.type_label(nil, email.types, "email"), email.value, email.line)
        end
        @contact.addresses.each do |address|
          row(Format.type_label(nil, address.types, "address"), Format.address_lines(address), address.line)
        end
        row("birthday", @birthday) if @birthday
        @contact.notes.each do |note|
          row("notes", note.value, note.line)
        end
      end

      # Membership as its own row, above the card's own: what a contact
      # belongs to frames the values under it, and several of those
      # values are the group's rather than the contact's. Every tag opens
      # the group it names (docs/DESIGN.md, "Relationships are
      # navigable"), the other half of the member tags on a group's own
      # card (Admin::GroupsShow). Rendered for a contact in no group
      # too when the dialog is on the page, even before any group
      # exists, because the row holds the way to join or start one —
      # the group card's members row, for the same reason, with its
      # "edit members" in the same place. Without the dialog the row
      # stands only when there is a member to name: an empty row with
      # nothing to press is nothing at all.
      #: () -> void
      def groups_row
        dt(class: "type-label") { "groups" }
        dd(class: "type-body-sm") do
          if @groups.any?
            div(class: "tag-set") do
              @groups.each { group_tag(it) }
            end
          end
          button(type: "button", data_size: "sm", popovertarget: GroupDialog::ID) { "edit groups" } if @dialog
        end
      end

      #: (Store::Group group) -> void
      def group_tag(group)
        a(href: "/groups/#{group.id}", class: "tag") { render GroupLabel.new(group:) }
      end

      # The type in one column and the value in the other, with the
      # group that lends the line named under the value when one does.
      # In the value cell rather than beside the type label: the type
      # column holds one thing for every row in the card
      # (docs/DESIGN.md, "Alignment is the layout"), and a mark on
      # the value is what says this address is the household's rather
      # than this contact's.
      #: (String type, String | Array[String] value, ?VCard::Parser::Line? line) -> void
      def row(type, value, line = nil)
        group = line && @contact.group_of(line)
        dt(class: "type-label") { type }
        dd(class: "type-body-sm") do
          render_value(value)
          # The groups row's own tag, pinned to this row's first line
          # at the right edge of the value column (admin.css) — under
          # the value it could be read as marking the row below.
          group_tag(group) if group
        end
      end

      #: (String | Array[String] value) -> void
      def render_value(value)
        if value.is_a?(Array)
          value.each do |line|
            div { line }
          end
        else
          div(style: "white-space: pre-wrap;") { value }
        end
      end
    end
  end
end
