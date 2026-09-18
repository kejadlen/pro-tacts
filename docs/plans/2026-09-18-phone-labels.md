# A phone keeps the label beside it

2026-09-18. A number Contacts labels arrives as two lines, and this
address book kept neither the label nor anywhere to put one. `Phone`
grows a label, read off the `X-ABLabel` sharing the line's property
group, and the macOS importer stops dropping it. No card already in the
store is rewritten.

## A label is a line, not a parameter

macOS spells a custom phone label as a property group: the number and
its label as two lines under a shared `item` prefix.

```
item3.TEL;type=pref:+19726769177
item3.X-ABLabel:Google Voice
```

The alternative was a `TYPE` parameter of our own — `TEL;TYPE=googlevoice`
— which `Contact#types_of` would read today with no new code at all. The
round trip settles against it. `docs/apple-contacts.md` ("An address type
the client cannot model becomes a custom label") records that a `TYPE`
the client has no field for is not dropped but *moved*: `ADR;TYPE=dom`
came back as `item1.ADR` + `item1.X-ABLabel:dom`, on an address nobody
edited. A label written as a type becomes a label on the client's first
touch, so the reader has to understand the group form regardless. Writing
the type first buys nothing and costs a second spelling.

The group form survives its own round trip. From the second probe in "An
annotation survives only on its own line", a `TEL` and the `X-ABLabel`
anchoring its group came back together, renumbered from `item1` to
`item2` but still bound. It was the third line in that group — a marker
of our own — that came back orphaned. Two lines is the shape the client
keeps; three is not.

## What the data has

Every `X-ABLabel` across the plans in `data/imports`, by the property it
annotates:

| Count | Property | Label |
|---|---|---|
| 31 | `EMAIL` | `_$!<Other>!$_` |
| 11 | `URL` | `_$!<HomePage>!$_` |
| 7 | `TEL` | `Google Voice` |
| 3 | `X-ABRELATEDNAMES` | `_$!<Spouse>!$_`, `_$!<Father>!$_`, `_$!<Sister>!$_` |

Phones only, for now. Emails and addresses can take a label the same way
when there is a reason to; today the only label on an email is Apple's
own `Other`, which says less than the word "email" the screen already
shows.

That also settles what to do about `_$!<Other>!$_` on a phone: nothing.
No phone carries a wrapped label, and the importer's discipline is that
it knows only what it has been taught
(`2026-09-16-importing-from-macos.md`, "The builder knows only what it
was taught"). A rule filtering a value nobody's card holds is a branch
written against a guess. A phone labeled `Other` later arrives reading
`Other`, and that is the point to decide.

The unwrap itself still happens. Apple wraps its own vocabulary, and
`Macos.related_names` already carries the regex for it inline; it moves
beside `escape` and `unescape` in `vcard.rb`, where both callers can
reach it.

## Reading

`Phone` gains a `label` beside `value`, `types`, and `line`. The two are
different facts and the cards hold both: `TEL;type=CELL;type=VOICE`
carries a type and no group, `item3.TEL;type=pref` a group and no type
(`pref` ranks a line rather than naming a kind, and `Contact#types_of`
drops it). Where a row has both, the label wins on screen, which is what
Contacts itself shows.

The label is on a different line than the row it describes, so
`Contact#phones` needs a map of property group to label built from
`vcard.properties` before it walks the `TEL` rows. `Admin::Format.type_label`
grows a label arm ahead of its types arm, which lights up the show screen
and the edit screen's row captions together — both already render that
span.

Reading the composed card rather than the stored one is safe here.
`db/migrations/004_groups.rb` refuses a grouped spelling in a group's
lines by CHECK, and names this exact hazard: an `item1.ADR` would need
its `item1.X-ABLabel` beside it. A group lends bare `ADR` and `NOTE` and
nothing else, so an inherited line can never collide with a member's own
`item` numbering.

## The plan card carries one

A plan's phone is a bare string today, which has nowhere to put a label.
It becomes a mapping, the shape `addresses` already takes, with the blank
key left out rather than written empty:

```yaml
phones:
  - number: "+17863533802"
    label: Google Voice
  - number: "(425) 502-5647"
```

`Card.read`'s `texts?` check becomes a shaped one like `address?`, and
refuses anything else — no leniency for the old string. Nothing re-reads
a finished plan's card files: `Plan#card` is only called for contacts a
step has not carried yet, and a plan every step has finished yields none.

`Macos.entry` reads the label beside each carried `TEL` instead of
dropping it with the other annotations. A label whose group holds no
carried line is still a line with no explanation, and stays unknown.

Writing it stays out of `Admin::CardForm`. The form has no label field
and is not growing one here, so a labeled phone is written where the
picture is written — directly in `Card#contact`, which already inserts
the `PHOTO` line for the same reason. Unlabeled numbers keep going
through `new_phone` as bare `TEL:` lines. The card is built from nothing,
so its `item` numbers count up from one; finding a free number in a card
that already has groups is the editor's problem, and waits for it.

`rake import:macos:plan` prints each card's phones in its summary, and
needs the number and its label formatted rather than the mapping.

## Nothing already imported is rewritten

Three populations, and only one of them moves.

The 26 contacts already landed stay as they are. Reading a label off a
group is a no-op on a bare `TEL:`, so the three Google Voice numbers
among them keep showing as plain phones. Their labels are still in
`source.vcard` in the landed plans, so a backfill is available whenever
it is wanted. It is not this change.

The plan still to land lost its labels when it was written, not when it
will be executed — `Macos.entry` reads `TEL` values at plan time. Its
card files hold bare numbers already, so executing it after this change
still imports three unlabeled. It is deleted and re-planned instead. That
has to happen after the change lands, and the stale plan has to be gone
before the new one is built: `import:execute` takes the oldest plan still
to land, which would otherwise be the stale one.

Plans built after that carry labels.

## What this leaves

The web editor shows a label and cannot set one. Giving it that needs a
free-`item`-number read on `VCard`, a second input on a phone row, and
one rule that is easy to get wrong: removing a phone has to remove the
label line with it, or the `X-ABLabel` is left naming nothing.

Emails and addresses read no label. The group map is the whole mechanism
and it is not phone-specific, so the cost of adding them later is a field
and a lookup each.

The three landed contacts with a Google Voice number are unlabeled in the
store, recoverable from their plans.
