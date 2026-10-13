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
    # Name only: what a created card carries, and why nothing more, is
    # CardForm.new_card's; everything else arrives through the editor
    # (ContactsEdit). The middle box stands outside the required pair —
    # it is never the name a contact is made by — so it carries no rule
    # of NamePair's.
    #
    # Each name box is `required` while the other is blank (NamePair),
    # native validation no browser submit gets past; the server's
    # backstop is Web's POST /contacts. `autofocus` fires when the
    # popover is shown, being scoped to the popover.
    #
    # No company variant (docs/plans/2026-09-24-company-cards.md,
    # "Creating"). The editor knows a company card when it edits one
    # (Contact#company?).
    class ContactDialog < Phlex::HTML
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
