require "pro_tacts/admin/phlex"

module ProTacts
  module Admin
    # The new-contact dialog — the dashboard's quiet add affordance,
    # opened and closed by the Popover API rather than by script or a
    # server round trip: the add button carries `popovertarget`, the
    # element carries `popover`, and the browser does the rest — top
    # layer, a painted ::backdrop (Gloss's own dialog::backdrop rule),
    # light dismiss, Esc. That is the whole reason this dialog is a
    # popover and not a `showModal()` dialog: the admin UI is
    # script-free (see Layout), and a popover is the one declarative
    # way to get modal behavior out of markup alone. Values survive a
    # light dismiss — the element stays in the page, only hidden — so
    # an accidental outside click costs nothing.
    #
    # Gloss's Dialog contract styles the element: header, body, footer
    # as direct children. The submit button in the footer reaches the
    # form above it by id, since a footer sibling is not inside the
    # form.
    #
    # Name only, by task uw's first cut: a created card has no prior
    # octets to preserve, so a form is safe for it, and everything else
    # a contact carries arrives by editing the record — which belongs
    # on the details page, where the surgical mutator will live. N and
    # FN both written because RFC 2426 section 4 requires them of every
    # card; the two name fields are N's first two components
    # (family;given), and FN is derived from them in the western order
    # the fixture sessions show macOS writing.
    #
    # A popover cannot be declared open in markup, so the empty-name
    # refusal is not a re-opened dialog: the first field is `required`
    # — native validation, which no browser submit gets past — and the
    # server's backstop for a hand-crafted empty POST answers with a
    # toast on the dashboard instead (see Web's POST handler).
    # `autofocus` fires when the popover is shown (it is scoped to the
    # popover, so the header search's own page-load autofocus stands).
    class ContactDialog < Phlex::HTML
      # @rbs @query: String

      #: (query: String) -> void
      def initialize(query:)
        @query = query
      end

      def view_template
        dialog(id: "new-contact", popover: "auto") do
          header { "New contact" }
          form(id: "new-contact-form", action: "/contacts", method: "post") do
            label(class: "field") do
              plain "First"
              input(type: "text", name: "first", required: true, autofocus: true)
            end
            label(class: "field") do
              plain "Last"
              input(type: "text", name: "last")
            end
            # The search the dialog opened over — opening a popover
            # loads no page, so this survives only the failed-create
            # re-render, keeping the results the user was looking at.
            input(type: "hidden", name: "q", value: @query)
          end
          footer do
            button(type: "button", popovertarget: "new-contact",
                   popovertargetaction: "hide") { "Cancel" }
            button(type: "submit", form: "new-contact-form",
                   data: {variant: "primary"}) { "Create" }
          end
        end
      end
    end
  end
end
