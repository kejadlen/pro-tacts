require "pro_tacts/admin/phlex"

require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # GET /contacts/:id/edit — the editor
    # (docs/plans/2026-09-05-web-card-editor.md): an explicit mode
    # rather than an always-editable page, one form over the
    # properties the save knows how to address. The cardinality-1 set
    # — name, nickname, note — saves through VCard#replace under each
    # field; the phone rows save through VCard#substitute, each named
    # by its line's digest. Emails and addresses arrive with their
    # own stage, birthday last.
    #
    # The fields prefill from the accessors' unescaped readings, and
    # blank equals absent on the way back (Web#edited_card), so write
    # and read agree on what an empty value means. The etag rides
    # along hidden — the snapshot guard's half, the POST's refusal
    # being the other. `autofocus` on the first field: this screen's
    # entry point is the name, not the header search.
    class ContactsEdit < Phlex::HTML
      # @rbs @contact: Contact
      # @rbs @notice: String?
      # @rbs @first: String?
      # @rbs @last: String?

      #: (contact: Contact, ?notice: String?) -> void
      def initialize(contact:, notice: nil)
        @contact = contact
        @notice = notice
        # N's first two components (RFC 2426 section 3.1.2: family;
        # given) — the two fields the create dialog also asks for. The
        # remaining three are preserved byte-for-byte by the save's
        # raw splice (Web#n_line), never rendered here.
        family, given = contact.name_components || []
        @first = given
        @last = family
      end

      def view_template
        render Layout.new(title: "Edit #{@contact.name || @contact.id}", notice: @notice) do
          # The caption-to-card block the details page uses (.record in
          # admin.css): the back link is this card's caption row too,
          # inside the .record-nav that page wraps it in. The row's
          # height comes from that element rather than the label, so a
          # bare link here is the shorter of the two rows and the card
          # under it lands higher than it does on the details page.
          div(class: "record") do
            div(class: "record-nav") do
              a(href: "/contacts/#{@contact.id}", class: "type-label") {
                "‹ #{@contact.name || @contact.id}"
              }
            end
            div(class: "card") do
              div(class: "card-body") do
                form(action: "/contacts/#{@contact.id}", method: "post", class: "field-stack") do
                  input(type: "hidden", name: "etag", value: @contact.etag)
                  label(class: "field") do
                    plain "First"
                    input(type: "text", name: "first", value: @first,
                          required: true, autofocus: true)
                  end
                  label(class: "field") do
                    plain "Last"
                    input(type: "text", name: "last", value: @last)
                  end
                  label(class: "field") do
                    plain "Nickname"
                    input(type: "text", name: "nickname", value: @contact.nickname)
                  end
                  # A phone row edits its value and nothing else: the
                  # TYPE parameters ride in the line's own header,
                  # which the save keeps (VCard.header_of) — a header
                  # rebuilt from form fields would drop the parameters
                  # no field models, and macOS writes three TYPE
                  # parameters on one TEL. The digest in the field's
                  # name is the row's address, and a blank value
                  # removes the line. Identical duplicate lines share a
                  # digest and therefore a field name, and Rack keeps
                  # the last value of a duplicated name — editing one
                  # of a pair of byte-identical rows means blanking
                  # one, saving, then editing the other.
                  @contact.phones.each do |phone|
                    label(class: "field") do
                      plain phone.type || "phone"
                      input(type: "tel", name: "phone[#{phone.line.digest}]", value: phone.value)
                    end
                  end
                  # One add-row: a value lands as a bare TEL before
                  # END:VCARD, and blank inserts nothing — inserting
                  # absence is a no-op, the plan's rule for new rows.
                  label(class: "field") do
                    plain "add phone"
                    input(type: "tel", name: "new_phone")
                  end
                  label(class: "field") do
                    plain "Note"
                    textarea(name: "note", rows: 4) { @contact.notes.to_s }
                  end
                  # Save is the form's submit; Cancel is navigation — a
                  # link in Gloss's `.btn` contract, which is what an
                  # anchor that acts like a button opts into.
                  div(class: "form-actions") do
                    button(type: "submit", data: {variant: "primary"}) { "Save" }
                    a(href: "/contacts/#{@contact.id}", class: "btn") { "Cancel" }
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
