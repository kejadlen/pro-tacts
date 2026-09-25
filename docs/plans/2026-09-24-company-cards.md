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

The wire shape is recorded, not remembered: the PUT a real client
sent (log/dev.log, 2026-09-24; macOS 27.0) writes a company card
with `N` empty — `N:;;;;` — the name in `FN` and `ORG` both, and the
flag. `test/fixtures/cards/company.vcf` carries those bytes. The
older shape this task's description recalled, the name in N's family
slot, is handled too — the editor reads whichever holds it — but no
client here has been seen sending it.

## Creating

There is no web-side create for an organization, and not for want
of trying: a Company checkbox inside the dialog rendered wrong
(a checkbox is no Gloss Field control), rendered right it made the
popover lurch (a popover sizes to its content, and the toggle
swapped three fields for one), and a second popover of its own
doubled the dialog for a rare case. Each shape cost the common
path more than the rare one was worth. What made the cut easy is
that the other paths are the real ones: a client's own Company
flow PUTs a finished card — proven on the wire, including the
two-step create where the first PUT is an empty shell and the name
lands with the second — and import is the bulk path, once `KNOWN`
lets `ORG` and the flag through.

## Editing

A company card's editor shows the one Organization field where the
pair stands. Its wire name is `last`, because that is where the save
writes the name — N's family slot, the component `CardForm.n_line`
splices — and the existing save machinery needed nothing beyond the
prefill: the field submits as the family half, `edited_fn` rewrites
`FN` when it moves, and the nameless backstop refuses a blank.

The prefill reads the name from wherever the card holds it — the
family slot, then `FN`, then `ORG`'s own name — because the real
wire shape (above) leaves `N` empty, and a field prefilled from the
family slot alone would have opened blank and refused its own save.
An untouched save on such a card writes the name into `N` as its
side effect, which is the editor's contract kept: the field owns
the name, and the name now lives where the field writes it.

One policy, stated plainly: a save does not touch `ORG`. The editor
writes the lines its fields own, and `ORG` is not one of them — a
renamed company can drift from the `ORG` it arrived with, invisible
here (no screen renders `ORG`) and editable on any client.

## Search

`ORG` joined the fields the dashboard's `matches?` scans, beside the
nickname: "acme" finds both Acme the card and the person who works
there. An organization card's own name is its `FN`, which the name
match already read.
