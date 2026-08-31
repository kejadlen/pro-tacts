# Birthdays are partial dates

2026-08-31. The app models a birthday as a date with any of its fields
missing. No vCard 3.0 value can say that, so birthdays become the second
thing after groups where the card served is not the card stored.

Groups were the first such divergence, and more are coming. The pattern
they established — compose on read, subtract on write — is the one this
reuses rather than replaces.

## The model

RFC 6350 section 4.3.1 already defines the shape, so the app takes it
rather than inventing one:

```
date = year [month day]
     / year "-" month
     / "--"     month [day]
     / "--"      "-"   day
```

Six combinations, not eight. A year with a day and no month is not among
them, and neither is nothing at all. Three independently optional fields
would admit both, and every layer downstream — the editor, the
validation, the display — would have to decide what they mean. The
grammar decided already.

Time is not in the model. RFC 2426 section 3.1.5 permits
`BDAY:1953-10-15T23:10:00Z`, and a card carrying one loses its time on
the way in. That is the one deliberate loss here, and it is the point of
the feature rather than a concession to it: a birthday is a date.

## Why it cannot live in the card

RFC 2426 section 3.1.5 defers `date-value` to [MIME-DIR], which is RFC
2425, now vendored. Its section 5.8.4 settles the question outright:

```
date = date-fullyear ["-"] date-month ["-"] date-mday
```

All three components are required. There is no reduced form and no
truncated one — those arrived with vCard 4.0, which RFC 6350 section
4.3.1 grants explicitly. A 3.0 card cannot say "April 12" without a year.

Which is why Apple invented `X-APPLE-OMIT-YEAR`. A birthday with no year
arrives as

```
BDAY;X-APPLE-OMIT-YEAR=1604:1604-01-01
```

with 1604 as a sentinel in both halves. That is a real capture, in
`test/fixtures/macos-exchange/10-put-contact-edit/request`, and it
settles the open question at
`2026-08-24-vcard-storage-and-groups.md:215`.

So the birthday is database state, in its own table, and no stored card
carries a `BDAY` at all. A submitted one is lifted out on write and
composed back in on read, exactly as a group's shared address is.

The cheaper design was rejected. It keeps `BDAY` in the card whenever the
wire can hold it — complete dates, and month-and-day through Apple's
parameter — and moves only the unrepresentable shapes into a table. That
preserves the strong ETag for most contacts and needs no subtraction in
the common case. It also makes a birthday's authoritative home depend on
its own precision: editing 1985-04-12 down to April 12 migrates it
between two stores, and every read has to look in both. The subtraction
machinery has to exist for the other shapes regardless, so the split buys
nothing it does not also complicate.

## What goes on the wire

| Model | Served |
|---|---|
| year, month, day | `BDAY:1985-04-12` |
| month, day | `BDAY;X-APPLE-OMIT-YEAR=1604:1604-04-12` |
| year alone, year and month, or day alone | nothing |

Emitting Apple's sentinel is reading the ingest rule backwards, and it is
the only way a year-less birthday reaches a device. Sending nothing
instead would mean a birthday someone typed on their Mac is absorbed into
the model and then vanishes from Contacts on the next sync.

The remaining three shapes have no form any client is known to accept.
They live in the web UI and go nowhere, which is the honest outcome —
the alternative is inventing precision the record does not have.

## Absence is a deletion only for what we send

A submitted card with no `BDAY` means two different things:

- The model holds a shape we serve, so the client saw a `BDAY` and
  removed it. That is a deletion.
- The model holds a shape we do not serve, so the client never saw one.
  Nothing changed.

This is the same asymmetry an inherited group property has, and it is
what makes the round trip idempotent: serve `S+B`, take `S+B` back,
subtract, get `S`.

The sentinel is a client convention, not a value. A plain
`BDAY:1604-01-01` with no parameter is a real birthday in 1604 and stays
one. Only the parameter makes the year a sentinel.

## The strong ETag exception widens

`2026-08-24-corrections-from-the-first-write.md` narrowed the ETag-less
PUT to one case: a group member whose inherited properties are
subtracted. Birthdays add a second, and a much larger one. Because
`BDAY` never lands in the stored card, stored is not equal to submitted
for any contact whose card carries a birthday, and RFC 6352 section
6.3.2.3 conditions the strong ETag on exactly that comparison. Those
responses omit it and the client refetches.

Whether Contacts handles an ETag-less PUT response gracefully is still
unanswered, and it now gates more than groups.

## Open questions

The wire questions are empirical and the seed cards in
`test/fixtures/cards/` are the experiment: eight contacts, one per
birthday form, served by `rake dev` to a real client. For each, the
question is what Contacts renders and what it sends back.

- Does Contacts render `X-APPLE-OMIT-YEAR` on a card it did not write?
  Reading its own output back is not the same test.
- Does it accept RFC 6350's reduced forms — `--0412`, `1985-04`, `1985`,
  `---12`? If it accepts `--0412`, the sentinel goes away and three more
  shapes reach the wire.
- What does it do with a `BDAY` date-time?
- Does `X-APPLE-OMIT-YEAR` survive a round trip, and is its value always
  1604? One capture is one observation.

The admin contact view on `admin/read-only-contacts` matches `--MM-DD`,
an extended-format truncation that RFC 6350's basic-format grammar does
not produce and no client is known to emit. The fixtures cover that form
too, so the guess gets tested rather than carried forward. The same code
renders a year-less Apple birthday as January 1, 1604, which is the bug
this design exists to prevent.
