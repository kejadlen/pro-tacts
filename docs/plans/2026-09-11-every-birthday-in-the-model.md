# Every birthday goes in the model

2026-09-11. Every well-shaped BDAY a client sends moves into the
birthdays table, and only the two shapes that survive a round trip
through both Apple clients are sent back. The other four are kept and
shown in the admin, but no served card carries them.

This replaces the carry in
`2026-09-01-birthdays-across-a-rewrite.md`, and reverses the 1604 rule
in `2026-08-31-partial-birthdays.md`.

## What survives a round trip

From the macOS probe (`docs/apple-contacts.md`, "A birthday the client
cannot render is dropped from the card") and the iOS one ("iOS writes a
birthday it cannot hold as a date it made up"):

| Shape | macOS | iOS |
|---|---|---|
| Full date | survives | survives, with `value=date` added |
| Month and day | the sentinel survives | survives only if 1604 means no year |
| Year and month, year, day | dropped | dropped, or a date it made up |
| Month alone | not observed | dropped |

A full date and a month-day are the two `Birthday#to_line` sends.

## Why the carry went

The carry existed because a BDAY in a shape no client renders stayed
in the stored card, got served, got dropped by the client, and had to
be put back. The 2026-09-01 plan kept it in the card rather than the
model because moving it would make it vanish from every served card.

That vanishing costs nothing: no client displays those shapes, so
serving them only ever gave a client something to drop or, on iOS, to
turn into a made-up year-2 date. With every well-shaped BDAY in the
model, no stored card holds a birthday a client cannot handle, and the
only rule left is the one the model already had: a birthday row no
client was sent survives a card sent back without one.

The same move fixes a spelling iOS misreads. `BDAY:--11-27` served
verbatim showed on iOS as January 27 of the year 2 and was written
back that way; in the model it is sent as the sentinel instead.

## 1604 means no year

iOS writes the Apple sentinel back as `BDAY;value=date:1604-MM-DD`,
without `X-APPLE-OMIT-YEAR`. The 2026-08-31 plan read a bare 1604 date
as a real birthday in 1604, which would turn every no-year birthday
into a 1604 one after an iOS save. A family address book has nobody
born in 1604, so a full date in that year now reads as a month and day,
parameter or not.

The model can still hold a year of 1604 from the admin editor, and it
goes out as a bare 1604 date that reads back as a month and day. That
is the one shape this gives up.

## One line, three outcomes

`BirthdayLine.read` sorts a submitted BDAY line into one of three
variants, and `Store#put` has one arm for each:

- `Modeled`: a birthday the model takes. It leaves the card.
- `Unrecognized`: a BDAY the model does not take — an unknown value, a
  parameter other than `VALUE=date` or the sentinel's, or a grouped
  `item1.BDAY`. It stays in the card verbatim and is reported.
- `Unreadable`: a line the parser could not read. It stays in the card,
  already reported by `Web#report_unreadable_lines`.

A card with more than one BDAY keeps them all in the card and is
reported whatever they hold: a contact has one birthday.

The variants are matched with `case`/`when`. Steep 2.1.0.dev.1 does not
check the bodies of `case`/`in` branches at all — a missing method in
one reports nothing — while `case`/`when` narrows the union by class.
`when` does not raise on an unmatched value, so each match ends in an
explicit raise.

## No migration

Cards stored under the old rule can hold BDAY lines this change would
move into the model, and a rewrite now drops such a line with a report.
No deployed database held any cards when this landed, so nothing moves
them.

## Migration 002 reads through the new rule

`db/migrations/002_birthdays.rb` calls `Birthday.from_property`, so
run today against a database that predates it, it would move every
well-shaped BDAY rather than the two spellings it moved when it was
written. Every database that has run 002 is unaffected, and a new one
has no cards when 002 runs.
