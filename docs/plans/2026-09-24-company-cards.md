# Company cards

2026-09-24. The web UI can make an organization card and knows one
when it edits one (task `qtw`, "Support non-person contacts like
companies"). Storage needed nothing: cards are stored as sent, so the
org cards Contacts.app writes already carry everything through —
`ORG`, the name in N's family slot, and Apple's `X-ABShowAs:COMPANY`.

## What a company card is

`X-ABShowAs:COMPANY` is the flag, read by `Contact#company?` — the
phone labels' own precedent for trusting an X- property. It is
display's fact alone, and a different property from `ORG`: a person
carries `ORG` without the flag, and nothing binds the two.
`Contact#organization` reads `ORG`'s whole text (RFC 2426 section
3.5.5) — what a search reads, no screen having asked for the
components apart yet.

## Creating

The dashboard's new-contact dialog carries a quiet "New company"
link at the foot of its actions, opening a second popover of its own:
one Organization field, the same Create. The first cut was a Company
checkbox swapping the name fields inside the one dialog, and it was
wrong twice — a mode switch inside a three-field form, and a popover
resizing around its own content every time it flipped. The second
dialog is the honest shape: the person's dialog is exactly what it
was, and the swap is whole popovers (`popover: "auto"` closes the
first when the second opens), not fields inside one. The org form
posts `company` with the one name, and `CardForm.new_org_card` writes
the shape Contacts.app emits: the name in N's family slot, `FN` and
`ORG` of the same, the flag. An organization is made here, not by
converting a person later — the editor never flips the flag.

## Editing

A company card's editor shows the one Organization field where the
pair stands. Its wire name is `last`, because that is the truth of
where the name lives — N's family slot, the component `CardForm.n_line`
splices — and the existing save machinery needed nothing: the field
submits as the family half, `edited_fn` rewrites `FN` when it moves,
and the nameless backstop refuses a blank.

One policy, stated plainly: a save does not touch `ORG`. The editor
writes the lines its fields own, and `ORG` is not one of them — a
renamed company can drift from the `ORG` it arrived with, invisible
here (no screen renders `ORG`) and editable on any client. The
create writes it because a created card has no prior octets to
preserve.

## Search

`ORG` joined the fields the dashboard's `matches?` scans, beside the
nickname: "acme" finds both Acme the card and the person who works
there. An organization card's own name is its `FN`, which the name
match already read.
