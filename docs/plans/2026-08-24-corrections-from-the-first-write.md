# Corrections from the first real write

2026-08-24, later the same day. macOS Contacts wrote to this server for
the first time, and the captures in `log/unhandled` contradict three
things in `2026-08-24-vcard-storage-and-groups.md`. That record stands
as written; this one says what the first real card changed.

The client behavior itself is in `../macos-contacts.md`. This covers
only what it means for the storage design.

## Diffing a submitted card has to be semantic

The classification rule says to recompute what was last served and diff
the submitted card against it, treating each property that moved as an
edit. That silently assumed the client returns untouched properties in
the form they were sent. It does not:

```
ADR;TYPE=home  ->  ADR;type=HOME;type=pref
```

Same address, same seven components, byte-for-byte different. Contacts
lowercases parameter names, uppercases values, fills in defaults, and
reorders properties on every card it touches.

A byte-wise diff therefore reports every property as modified, including
the ones a group injected. Under the rule that an edit to a shared value
updates the group, that turns every save of any member's card into a
group rewrite fanned out to every other member — a phantom edit,
repeated on each sync, from a card nobody changed.

The comparison must normalize before it decides anything: parameter name
case folded, parameter values treated as an unordered set, the repeated
`type=` spelling and the comma-separated list treated as equivalent
(RFC 2426 section 3.3.1 permits both), property order ignored, and text
values compared after unescaping. Only a difference that survives all of
that is an edit.

This does not change the subtract-and-compose model. It changes what
counts as equality inside it, which is the part the model rests on.

## BDAY is semantic loss, not syntactic drift

The storage record uses `BDAY` as its example of the cheap mismatch —
meaning preserved, bytes different. That holds for a birthday with a
year. It is wrong for one without:

```
BDAY;X-APPLE-OMIT-YEAR=1604:1604-01-01
```

The fact that the year is unknown lives entirely in a non-standard
parameter, with 1604 as a sentinel in both halves. Parse that into a
date type and the parameter is gone, the sentinel becomes real, and
re-rendering gives the contact a birthday in 1604. A card with a known
year is a plain `BDAY:1900-01-01`, so the two are not even the same
shape.

The correction is to the category, not the conclusion. This is a
stronger argument for storing the document than the one the record
makes: the loss needs no `X-` property to demonstrate, only a birthday
with no year.

## The strong-ETag path is reachable after all

The record treats round-trip drift as costing the strong ETag on PUT,
and argues the refetch is cheap. Rereading RFC 6352 section 6.3.2.3, the
comparison it specifies is between what the server **stores** and what
was **submitted** — not between what the server previously served and
what came back. Storing the submitted card verbatim makes those equal by
construction, so a strong ETag is allowed on every ordinary PUT.

Drift between a card we rendered and the card Contacts returns costs
nothing. It is paid once, when the KDL-rendered cards are replaced by
Apple-shaped ones, and never again.

The exception is unchanged and is now the only one: a member of a group
has inherited properties subtracted before storage, so stored is
deliberately not equal to submitted, and those responses must omit the
strong ETag.

## Still unknown

Whether Contacts handles an ETag-less PUT response gracefully cannot be
answered until PUT is implemented, since the server currently 404s and
that path never runs. It belongs to the PUT task.

Whether the client preserves a parameter of this server's own invention
is untested — it emits its own non-standard parameters freely, but that
is not the same question. It matters less now that the marker parameter
is a hint rather than the mechanism.

No `X-ABADR`, `X-APPLE-SUBLOCALITY`, `X-ABLabel`, or `item1.` grouping
appeared on any captured card. The storage record says macOS leans on
those heavily, which overstates what a card without custom labels
carries. `PRODID`, `REV`, and `NOTE` alone are enough to make its point.
