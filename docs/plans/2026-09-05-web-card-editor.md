# The web card editor: an edit screen whose save is addressed operations

2026-09-05. Task uw's remaining half — editing contacts from the
browser. Create landed as a name-only popover dialog (qvnnvptr); this
doc designs the editing that follows. The task's own warning is the
specification: "a form that round-trips through a struct discards
every property it has no field for. Saving must apply a surgical
change to the stored card and leave untouched properties
byte-identical." Everything below exists to make that true by
construction rather than by care.

Builds on docs/plans/2026-09-05-contact-takes-its-structure.md, which
lands first and is referred to here as the contact refactor.

## The hazard, and the shape that removes it

An HTML form cannot hold a card open across a request. What travels is
the field set, so a save that reconstructs the card from its fields
loses every line the form never rendered — PHOTO, REV, PRODID, the
X- properties macOS sends, the components of a structured value the
form doesn't show. The fix is not a more careful form. It is a save
composed of operations that each name the line they touch, applied to
the stored card's own bytes. A line the form has no field for is a
line the request never mentions, and what is never mentioned cannot be
lost.

So the editor's write half is three line operations over the card,
all on `VCard` beside `#extract` and `#insert`:

- `#replace(name, lines)` — for the properties a card carries one of
  (N, FN, NICKNAME, NOTE): swap the lines naming the property for the
  given ones at the first match's position, and insert before
  `END:VCARD` when the card lacks the property. Stricter than
  `extract` + `insert`, which would drag the property to the end of
  the card.
- `#substitute(digest, lines)` — for the properties a card carries
  many of (TEL, EMAIL, ADR): swap the one line whose verbatim bytes
  hash to the digest, or remove it when the lines are empty. The
  digest is the SHA-256 of the line's bytes: constant size, pure
  ASCII, no card content hidden in the page, and none of the
  newline-in-attribute pitfalls that carrying the bytes themselves
  would bring.
- `#insert(lines)` — already present, for new rows.

The read half feeds this: `Phone`, `Email`, and `Address` gain
`line:`, the parsed `Line` the value was read from. The accessors
currently fold lines into typed values at `contact.rb` and drop where
each came from, so no form could ever say "edit this phone." With
provenance on the shapes, the view renders each row from the same
object that knows its own bytes.

Digests are safe as addresses because of the snapshot guard below,
not on their own: within one render-to-save cycle the card is
verified unchanged, so a line's identity cannot have gone stale, and a
digest that misses despite a matching etag is an anomaly that refuses
loudly rather than guessing.

## The edit screen

An explicit mode, not a popover and not an always-editable page:
`GET /contacts/:id/edit` renders one form, `POST /contacts/:id`
applies it, and success is a 303 back to the details page, so the
back button cannot double-submit. POST stays the wire verb — HTML
forms speak only GET and POST, the admin surface's one client is the
form, and the DAV routes remain this app's real-verb surface. The
admin UI stays script-free (see `Admin::Layout`), which the Popover
API create dialog already established.

Blank means absent, uniformly, because write should agree with read:
the accessors already treat an empty property value as absent
(`Contact#text_of`), so submitting empty is the same rule in the
other direction. For a row with a digest, a blank value removes the
line. For a whole-property field (nickname, note), blank removes the
property. For a new row, blank is a no-op — inserting absence does
nothing. A row with a structured value (ADR) is removed only when
every component is blank, since partial blanks are legal empty
components; that is also how the reader treats one. The one exception
is forced by the spec, not by taste: N and FN are mandatory (RFC 2426
section 4), so a save whose name is blank throughout is refused.

The name field is two fields, first and last, matching the create
dialog. N's remaining components (additional, prefixes, suffixes) are
preserved byte-for-byte by splicing at the raw level — a split on
unescaped `;` over the still-escaped value, replacing the first two
components, joining again. No unescape-then-re-escape round trip,
which is not byte-stable: `VCard.unescape` leaves an unrecognized
escape like `\x` alone, and `escape` would double its backslash. FN
is re-derived from the two fields, the create flow's rule and what
macOS itself does when the name is edited. REV is not touched; the
change log is the record of when, and macOS re-stamps REV on its own
next rewrite.

The form carries the etag of the card it was rendered from, and the
POST refuses with a toast on the re-rendered screen when the stored
contact hashes differently — another tab or a DAV client edited the
contact in between, and silently applying this save over that one
would revert its changes. This is the same lost-update guard the DAV
PUT's If-Match gives clients (RFC 7232 section 3.1), and it shares
that path's millisecond race window between check and write: noted,
not closed, consistent with the surface the real client already
uses.

## Two write paths through the store

The editor mutates the stored card and must not go through
`Store#put` to store it. `put` is client-submission semantics: a
submitted card with no BDAY is a client that dropped the birthday,
and the rewrite arm at `store.rb:265` (`kept = existing &&
!existing.served? ? existing : nil`) deletes a served model row
accordingly. A stored-card edit carries no BDAY line by definition,
so an admin fixing a phone number through `put` would silently delete
the contact's birthday. Mutating the composed card and putting that
back happens to work, but only while model rows never coexist with
unrendered BDAY lines — an invariant that is currently unreachable
code away from changing (see the contact refactor's non-goals).

So the store gains `rewrite(id, stored_bytes)`: upsert the card,
reindex it, record the change-log entry carrying the composed etag a
client would download, and touch nothing else. Two write paths is not
duplication — `put` answers "a client submitted a card," `rewrite`
answers "the store's own editor changed the stored one," and the
birthday is only the first fact those sentences treat differently.

This is also why the contact refactor lands first: `Contact.for(id:,
stored:, birthday:)` holding the stored card is what the editor
mutates, and it needs one addition the refactor's contracts don't
list — `Contact#stored` as a public reader, the editor's handle on
the bytes it edits. Digests computed from either card agree, because
composition only inserts the BDAY line before `END:VCARD` and rows
never address that line.

## Roads not taken

A subresource API (`POST /contacts/:id/name`,
`/contacts/:id/phones/:digest`, and friends) was designed first, at
equal length, and set down. The safety lives in the addressing, not
in the granularity: one form over digests loses nothing that many
small forms lose nothing of, and the single submit means one etag
check, one atomic write, one change-log entry per editing pass, and
one redirect instead of a chain of them. Real PUT and PATCH verbs
would have meant method-override middleware in a script-free app
whose admin API has exactly one client.

A modeless page — every row an always-visible inline form — carries
the same machinery in a heavier page, and an explicit edit screen
turned out simpler to build and to use: the details page stays a
clean read, the edit screen is one form, and the mode boundary is a
URL.

Per-row remove buttons (a `✕` with its own `formaction`) lost to
blank-equals-absent, which is uniform with the whole-property fields
and needs no second control.

A monolithic form without digests is the original hazard and needs no
rebuttal.

## Staging

0. The contact refactor — tasks ul and qzm, their own doc, unchanged.
   The editor builds on its constructor.
1. The edit screen with name, nickname, and note — `VCard#replace`,
   `Contact#stored`, `Store#rewrite`, the etag guard, the refusals
   (unknown id 404, blank name toast, stale etag toast). Only
   cardinality-1 properties, which exercises the whole pipeline end
   to end.
2. Phones — `line:` provenance, `VCard#substitute`, add-rows, the
   blank-remove rule.
3. Emails and addresses, the same machinery.
4. Birthday, last: it writes the model rather than the card, so it
   needs a store write that bumps the change log from the model side,
   and its own doc.

## Non-goals

- Birthday editing, deferred to its own doc for the reason above. The
  contact refactor already names the composed-etag question it turns
  on.
- Groups. No recorded client session sends grouped properties (see
  test/fixtures/macos-exchange); a digest addresses a grouped line,
  but the replacement renders ungrouped, and that is accepted until a
  client proves otherwise.
- Any change to the DAV surface. No route or response there moves.
- Modeling properties beyond the form's set. A property with no field
  is the design's central case, not an oversight.
