# Unrenderable birthdays ride across a rewrite

2026-09-01. macOS Contacts renders two of RFC 6350 section 4.3.1's six
birthday shapes: a full date, and a month with a day. For the rest —
year and month, year alone, month alone, day alone — it shows nothing,
and the next card it writes carries no BDAY at all. Editing an
unrelated field is enough; all three observed losses came from adding
a note.

## The old deletion rule guarded the wrong half

`Store#put` treated a submitted card with no BDAY as a deletion, with
one exception: the model row was kept when it held a shape no client
was served (`existing && !existing.served?`). That guards the model's
half. But a birthday in an unmodeled *spelling* never becomes a model
row — `Birthday.subtract` leaves the line in the card verbatim, per
RFC 6352 section 6.3.2.2 — and there is nothing in the birthdays table
to fall back on. The client rewrites the card, and the only copy goes
with it. The rule protected the shapes the model holds and lost the
ones the card holds, which is backwards: the card-held ones are
exactly those no client can round-trip.

They also cannot simply move into the birthdays table. The model has
no spelling that `compose` would put back on the wire for these
shapes, so a promoted birthday would vanish from every served card
instead of surviving in one — a read-side regression dressed as a fix.

## The divider is the shape, not the spelling

A rewrite with no BDAY means two different things, and "did the
client render this birthday" decides between them:

- macOS renders the unmodeled no-year spellings too (`--0412`,
  `--04-12`), so a rewrite that omits one is a user removing a
  birthday they could see. That deletion is honored.
- The four unserved shapes render nothing, so no client can have
  removed them. `put` carries those lines across the rewrite — the
  new stored card is the submission plus the stored BDAY lines,
  verbatim with their folds.

The carried spellings are a whitelist (`Birthday::UNRENDERED_VALUES`):
the four partial shapes, dashed as RFC 6350 section 4.3.1's examples
spell them, components in range. A value off the list — served in
any spelling, unpadded, out of range, unrecognizable — dies with the
rewrite that drops it, so garbage never becomes immortal. The day
`to_line` learns a verified spelling for one of the four — the
month-alone probe is still unrun — is the day its spelling leaves
the list; the tests pin the correspondence.

## What nobody recognizes is reported, not swallowed

A BDAY line that parses to a value neither modelable, rendered, nor
carried is unexpected input, and it meets two quiet fates: stored
verbatim with no one told (RFC 6352 section 6.3.2.2 keeps it, but
keeping is not reporting), or dropped by a rewrite that could not
have shown it. Both moments report to Sentry — the arrival in
`Store#put`'s split, the loss in its carry branch. The messages carry
no card content, per SentryScrubber's line: the values stay on the
machine, where the admin view shows them raw.

The classifiers themselves cannot raise — the whitelist matches or
does not, and `from_property`'s out-of-range rescue is what read
paths depend on — so there is no error to swallow on the way to a
classification. What is left is the classification, and the
unrecognized one is never silent.

## Where the layers sit

The surgery is not the model's. `Birthday` is a partial date and the
property-level reading of one (`from_property`, `to_line`, the
whitelist, the rendered set); `VCard` is the card — parsed beside its
bytes, Enumerable over its lines, one verb for taking a property's
lines and one for putting lines back; and `Store` owns the policy —
the deletion rule, the carry, and both reports — over the two.
Migration 002 spells its own split out against `VCard` and `Birthday`
directly, so what it did to databases that already ran it cannot
drift with the app's internals.

## The cost, taken deliberately

A birthday no client renders is now client-undeletable, the same
terms the model-row half of the rule already had: a PUT carrying any
BDAY replaces it, and deleting the contact removes it, but a rewrite
alone never will. The alternative is the silent loss the probe
recorded, which is worse for a family address book — the birthdays
these shapes hold are the partial ones ("1985, maybe April") that
nowhere else in the card is recorded.

## The wire consequences

The carried card is not the submitted bytes, so the PUT answer omits
the strong ETag (RFC 6352 section 6.3.2.3) and the client refetches —
which is what shows it the birthday survived its edit. The change log
and ctag move with the composed card as they already did.
