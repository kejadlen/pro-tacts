require "pro_tacts/admin/phlex"

require "pro_tacts/admin/name_pair"

module ProTacts
  module Admin
    # The new-contact dialog — the dashboard's quiet add affordance,
    # opened and closed by the Popover API rather than by script or a
    # server round trip: the add button carries `popovertarget`, the
    # element carries `popover`, and the browser does the rest — top
    # layer, a painted ::backdrop (Gloss's own dialog::backdrop rule),
    # light dismiss, Esc. That is the whole reason this dialog is a
    # popover and not a `showModal()` dialog: the admin UI is
    # not scripted (see Layout — Alpine is loaded, and opening a
    # dialog is not what it is there for), and a popover is the one
    # declarative way to get modal behavior out of markup alone. Values survive a
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
    # card; the three name fields are N's first three components
    # (family;given;additional), and FN is derived from them in the
    # western order the fixture sessions show macOS writing. The middle
    # box stands outside the required pair — it is never the name a
    # contact is made by — so it carries no rule of NamePair's.
    #
    # A popover cannot be declared open in markup, so the empty-name
    # refusal is not a re-opened dialog: each name box is `required`
    # while the other is blank (NamePair) — native validation, which no
    # browser submit gets past — and the server's backstop for a
    # hand-crafted empty POST answers with a toast on the dashboard
    # instead (see Web's POST handler).
    # `autofocus` fires when the popover is shown (it is scoped to the
    # popover, so the header search's own page-load autofocus stands).
    #
    # An organization is made by its own popover beside this one
    # (docs/plans/2026-09-24-company-cards.md), opened from the
    # footer's link — not by a toggle swapping the name fields, which
    # made the popover lurch around its own content-sized box. Created
    # here rather than converted from a person later: the editor
    # renders a company card's one name field, and nothing flips the
    # flag.
    class ContactDialog < Phlex::HTML
      # @rbs @query: String

      #: (query: String) -> void
      def initialize(query:)
        @query = query
      end

      def view_template
        dialog(id: "new-contact", popover: "auto") do
          header { "New contact" }
          form(id: "new-contact-form", action: "/contacts", method: "post",
               x_data: "{ #{NamePair.state(nil, nil)} }") do
            label(class: "field") do
              plain "First"
              input(**NamePair.first(nil, nil), autofocus: true)
            end
            label(class: "field") do
              plain "Middle"
              input(type: "text", name: "middle")
            end
            label(class: "field") do
              plain "Last"
              input(**NamePair.last(nil, nil))
            end
            # The search the dialog opened over — opening a popover
            # loads no page, so this survives only the failed-create
            # re-render, keeping the results the user was looking at.
            input(type: "hidden", name: "q", value: @query)
          end
          footer do
            # The company create's way in, on the footer's left (Gloss
            # right-justifies a dialog's actions; this is the one
            # thing on the other side). Opening the second popover
            # closes this one, `popover: "auto"` being the many-open-
            # at-once refusal, so the swap is whole dialogs rather
            # than fields inside one — a popover sizes to its content,
            # and fields swapping inside it made the box lurch.
            button(type: "button", style: "margin-right: auto",
                   popovertarget: "new-company") { "New company" }
            button(type: "button", popovertarget: "new-contact",
                   popovertargetaction: "hide") { "Cancel" }
            button(type: "submit", form: "new-contact-form",
                   data: {variant: "primary"}) { "Create" }
          end
        end

        # The company create's own popover, the person dialog's footer
        # link the way in. One field — an organization is known by one
        # name, the mononym's own rule — and the hidden `company` the
        # route branches on (CardForm.new_org_card). The same popover
        # machinery as the person's: Popover API open and close, no
        # script, values surviving a light dismiss, autofocus scoped
        # to the popover once shown.
        dialog(id: "new-company", popover: "auto") do
          header { "New company" }
          form(id: "new-company-form", action: "/contacts", method: "post") do
            input(type: "hidden", name: "company", value: "1")
            label(class: "field") do
              plain "Organization"
              input(type: "text", name: "organization", required: true, autofocus: true)
            end
            input(type: "hidden", name: "q", value: @query)
          end
          footer do
            button(type: "button", popovertarget: "new-company",
                   popovertargetaction: "hide") { "Cancel" }
            button(type: "submit", form: "new-company-form",
                   data: {variant: "primary"}) { "Create" }
          end
        end
      end
    end
  end
end
