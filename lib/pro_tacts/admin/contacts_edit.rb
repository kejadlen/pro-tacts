require "pro_tacts/admin/phlex"

require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # GET /contacts/:id/edit — the editor
    # (docs/plans/2026-09-05-web-card-editor.md): an explicit mode
    # rather than an always-editable page, one form over the
    # properties the save knows how to address. This stage carries the
    # cardinality-1 set — name, nickname, note — whose save is
    # VCard#replace under each field; phones, emails, and addresses
    # arrive with their own stages, birthday last.
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
          a(href: "/contacts/#{@contact.id}", class: "type-label") {
            "‹ #{@contact.name || @contact.id}"
          }
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
