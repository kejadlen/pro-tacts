# The birthday editor: a row that writes the model

2026-09-07. Task uw's last stage, deferred to this doc by
docs/plans/2026-09-05-web-card-editor.md's staging: "Birthday, last:
it writes the model rather than the card, so it needs a store write
that bumps the change log from the model side." Everything above is
that sentence unpacked.

## Why this row is not the others

The editor's safety so far is addressing: a row names the line it
edits by digest, and the save splices that line's bytes. A birthday
has no line to name. It is database state — a partial date has no
vCard 3.0 spelling, so it lives in the birthdays table and composes
into the served card on read (docs/plans/2026-08-31-partial-birthdays.md).
The birthday row's save is an upsert, not a splice, and its
prefill is the model (`Contact#birthday`), not a reading off the card.

That is also why the row can offer what no client renders. The
grammar's six shapes (RFC 6350 section 4.3.1) are all editable — a
year alone, a month alone, year-and-month, a day alone — because the
model holds them all and `Birthday#to_s` renders each. What `to_line`
cannot serve reaches no device and the row still round-trips it; that
is the documented fate of those shapes, not a new decision.

## The store write

`Store#rewrite` gains the birthday: `rewrite(id, vcard, birthday:)`,
required and without a default — `Contact.for`'s own rule, that an
optional nil lets a caller quietly hold no birthday off a contact
that has one, is why the parameter's meaning change must be noticed
at every call site. The web save always passes one: the parsed row
when the form posted it, the contact's current model when it did not
(a POST from anything but this form — the phones' own `is_a?(Hash)`
posture, where a group the request never carried touches nothing).

One transaction, one change-log entry, as before — but the entry's
etag is now the composed hash of the card *and* the birthday being
written, because a birthday edit moves the served card and a sync
token must see it. The entry's action stays `edit`: to a syncing
client the member changed at a new etag, which is all an edit says,
and migration 003 already admits it. The card upsert runs on a
birthday-only save too — identical bytes, but `updated_at` moves and
"recently updated" is the honester for it, the same trade the ctag's
comment records for rewrites that store identical bytes.

`write_birthday` is reused from `put` unchanged: an upsert for a
birthday, a delete for nil. Nil is all three fields blank — blank
equals absent, the form's uniform rule, so a birthday is removed the
way a phone row is.

## The one hazard: a card that carries its own BDAY

No stored card carries a *modeled* BDAY, but a card can carry lines
the model refused — the reduced forms, a foreign sentinel, a BDAY
sharing bytes with something else (Store#put's case analysis). For
such a contact the model is nil and the served card still shows the
card's own spelling, which is what the details page renders and the
raw vCard section shows.

A birthday submitted against that state would compose a second BDAY
beside the card's own, and the next client rewrite of that card lands
in put's cardinality-broken arm — reported, but a mess this editor
made. So the save refuses: a non-blank birthday row against a stored
card carrying BDAY lines is a toast and nothing written, the
blank-name backstop's shape. The whole save refuses, not just the
row — one submit, one etag check, one write, the plan doc's own
arithmetic.

The alternative — extract the card's BDAY lines and migrate the
birthday into the model — was designed down to its error and set
aside. For unmodelable spellings the extraction drops data or keeps
the line and recreates the double-BDAY; keeping them safe means
importing put's carried-and-lost machinery into the editor, which is
client-submission semantics, the exact thing `rewrite` exists to
avoid. The probe task (kxyvsxzx, "Probe the birthday shapes against
iOS Contacts") is what dissolves this class of states or makes it
worth serving; until then the refusal is the honest edge.

## The row

Three controls in the value column on one line — month as a select
of names (validated by construction, and names rather than numbers
is the friendlier read), day and year as number inputs with native
min and max. Order month, day, year, matching `Birthday#to_s`'s own
"December 10, 1985". A component is not an attribute and earns no
type column of its own; the caption is `birthday`, the row's one
label, and the controls carry their own aria-labels.

A shape the grammar refuses — a day with no month, digits where a
number should be — is refused with a toast and nothing written. The
browser's own input constraints make that a hand-crafted POST's
backstop, the name toast's sibling: `Birthday.new`'s ArgumentError
is the grammar's own refusal, caught at the one boundary where a
re-render is the fallback. The checks keep apply_edit's order — the
request's validity first (name, then the row's shape), the
conditionals on stored state after (the etag snapshot, then the
card's own BDAY).

## Non-goals

- Promoting the four unrendered shapes onto the wire, or any change
  to what `to_line` serves. That is the probe's question.
- The change-log display on the contact's page distinguishing a
  birthday edit from a card edit. The log records which side wrote;
  within the editor's side, which row, is not a fact anyone has
  asked for.
- Editing an unmodelable BDAY spelling in place. The refusal above
  is the scope; the raw card stays the truth for those.
