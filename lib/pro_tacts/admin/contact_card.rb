require "pro_tacts/admin/phlex"

require "pro_tacts/admin/avatar"
require "pro_tacts/admin/card_form"
require "pro_tacts/admin/format"
require "pro_tacts/admin/group_dialog"
require "pro_tacts/admin/group_tag"
require "pro_tacts/vcard"

module ProTacts
  module Admin
    # A contact's details as a card: the header its rows sit under and
    # the rows themselves, on docs/DESIGN.md's grid ("Alignment is the
    # layout", "Empty attributes do not render"). Each row leads with
    # its mono type label, no row's glyph being in Icon's set yet
    # (docs/DESIGN.md, the icon rule).
    #
    # The contact's own page (ContactsShow) renders it inside its
    # record, and an import's saved row renders it beside the card
    # that row arrived as (ImportSaved) — one renderer, so a property
    # one screen shows is a property the other cannot drop.
    #
    # `groups` is the contact's membership (Store#groups_of), the row
    # framing the values under it. Its "edit" needs GroupDialog on the
    # page, which both callers render, each telling the save where to
    # land.
    #
    # `walk` is the one difference between the two: the walk's read
    # screen (ImportSaved) supplies the card around the body, its trunk
    # being RecordCard's, and its groups row carries no "new", whose
    # save lands on the group it made rather than back on the walk.
    class ContactCard < Phlex::HTML
      # @rbs @contact: Contact
      # @rbs @groups: Array[Group]
      # @rbs @walk: bool

      #: (contact: Contact, groups: Array[Group], ?walk: bool) -> void
      def initialize(contact:, groups:, walk: false)
        @contact = contact
        @groups = groups
        @walk = walk
        @birthday = Format.birthday(contact)
      end

      def view_template
        return body if @walk

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
            # A person's organization, where Contacts.app shows it:
            # under the name, in body type because it is no name of
            # theirs. A company's is the name above it already.
            organization = CardForm.organization_of(@contact.vcard).to_s
            if !@contact.company? && !organization.empty?
              div(class: "type-body gl-muted", style: "margin-top: var(--gl-space-2xs);") { organization }
            end
          end
          # Only a picture earns this slot: an initials circle
          # beside the name in type-h2 would repeat what the name
          # already says. The dashboard rows keep theirs — there
          # the avatar is the row's visual anchor, not a caption.
          render Avatar.new(contact: @contact, size: "xl") if @contact.photo?
        end
        dl(class: "detail-grid") { rows }
      end

      private

      # Every row hands over the group that lends it, nil where the
      # card's own — provenance carried on the row
      # (Contact::Phone#lent_by and kin), not re-derived from the
      # composed bytes. The birthday hands over none: it is the model
      # beside the card, and a group holds only addresses and notes
      # anyway (see db/migrations/004_groups.rb).
      def rows
        groups_row
        @contact.phones.each do |phone|
          row(Format.type_label(phone.label, phone.types, "phone"), phone.value, phone.lent_by)
        end
        @contact.emails.each do |email|
          row(Format.type_label(nil, email.types, "email"), email.value, email.lent_by)
        end
        @contact.addresses.each do |address|
          row(Format.type_label(nil, address.types, "address"), Format.address_lines(address), address.lent_by)
        end
        row("birthday", @birthday) if @birthday
        note_rows
      end

      # The notes read as the editors do — the member's own card and
      # the inheritance — and not out of the one value the client is
      # served: a group's note keeps its own row and its group beside
      # it, the same standing every other lent row has
      # (docs/plans/2026-09-25-one-note-per-contact.md, "What the
      # admin screens read").
      #: () -> void
      def note_rows
        @contact.own.notes.each do |note|
          row("notes", note.value)
        end
        @contact.inherited.each do |lent|
          next unless lent.line[/\A[^;:]*/].to_s.casecmp?("NOTE") == true

          text = Contact.lent_text(lent)
          dt(class: "type-label") { "notes" }
          dd(class: "type-body-sm") do
            div(style: "white-space: pre-wrap;") { text }
            render GroupTag.new(group: listed(lent.group))
          end
        end
      end

      # Membership as its own row, above the card's own: what a contact
      # belongs to frames the values under it, and several of those
      # values are the group's rather than the contact's. Every tag opens
      # the group it names (docs/DESIGN.md, "Relationships are
      # navigable"), the other half of the member list on a group's own
      # page (Admin::GroupsShow). Rendered for a contact in no group
      # too, even before any group exists, because the row holds the
      # way to join or start one.
      #
      # "edit" opens the dialog over the groups that exist; "new" opens
      # the members screen of a nameless one not yet made, this contact
      # ticked, the household's start — a family needs no name to be
      # one, and the dialog's offer to make a group is a name typed.
      #: () -> void
      def groups_row
        dt(class: "type-label") { "groups" }
        dd(class: "type-body-sm") do
          if @groups.any?
            div(class: "tag-set") do
              @groups.each { render GroupTag.new(group: it) }
            end
          end
          if @walk
            edit_button
          else
            # The slash between the two is admin.css's, being no word
            # of the page's: drawn where they sit side by side and
            # dropped where a phone stacks them.
            div(role: "group", aria_label: "Groups") do
              edit_button
              a(href: "/contacts/#{@contact.id}/groups/new", class: "btn", data_size: "sm") { "new" }
            end
          end
        end
      end

      #: () -> void
      def edit_button
        button(type: "button", data_size: "sm", popovertarget: GroupDialog::ID) { "edit" }
      end

      # The type in one column and the value in the other, with the
      # group that lends the row named under the value when one does.
      # In the value cell rather than beside the type label: the type
      # column holds one thing for every row in the card
      # (docs/DESIGN.md, "Alignment is the layout"), and a mark on
      # the value is what says this address is the household's rather
      # than this contact's.
      #: (String type, String | Array[String] value, ?Group? lent_by) -> void
      def row(type, value, lent_by = nil)
        dt(class: "type-label") { type }
        dd(class: "type-body-sm") do
          render_value(value)
          # The groups row's own tag, pinned to this row's first line
          # at the right edge of the value column (admin.css) — under
          # the value it could be read as marking the row below.
          render GroupTag.new(group: listed(lent_by)) if lent_by
        end
      end

      # A lent row's group as the groups row read it, with its members.
      #: (Group lent) -> Group
      def listed(lent) = @groups.find { it.id == lent.id } || raise(ArgumentError, "group #{lent.id} lends a row but is not among the contact's groups")

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
