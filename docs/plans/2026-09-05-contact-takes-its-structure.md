# Contact takes its structure rather than parsing it back

2026-09-05. `Store` holds a `Birthday`, composes it into the served
card, and hands that card to `Contact`, which parses the same birthday
back out to answer `#birthday`. This removes the loop: Store passes the
model, Contact holds the stored card beside it and composes on read.
Amends docs/plans/2026-09-01-contact-is-the-model.md, which built the
reader this changes.

## The round trip is exact, and that is the problem

`store.rb:278` has `birthday` in scope, splices it into the card with
`with_birthday`, and constructs. `contact.rb:197` finds the BDAY in
that card and hands it to `Birthday.from_property`. The answer is
always the birthday Store already had, and provably so: a served card's
BDAY is either the line `to_line` composed — which `from_property`
accepts — or one the store left in the card, which `from_property`
refused, that refusal being why it stayed. There is no third case, so
the parse recovers a fact that never left the room.

The earlier doc defends the loop on the grounds that structure should
derive from bytes, and states its soundness argument conditionally: it
holds "because the two served forms are exactly the forms
`from_property` accepts." Inverse on those two, not in general. That
condition is load-bearing, and groups will not honor it. A group
composes inherited properties into the served card, and nothing in the
composed bytes tells an inherited TEL from an own one — which the same
doc concedes at its line 108, routing that knowledge to Store rather
than Contact. Deriving from bytes does not merely get expensive at
groups; it stops being able to answer. The birthday loop is only
redundant today. It is the shape that fails later.

## Contact composes, not Store

The obvious move — Store passes both the composed card and the model —
puts one fact in the argument list twice in two forms, held consistent
only because the two lines sit next to each other. That is the "one
fact, two homes" objection the earlier doc raised, and it lands.

So Contact takes the *stored* card and the birthday, and derives the
served one. Those two inputs are independent rather than duplicated:
`put` either moves a BDAY line into the model or leaves it in the card,
never both. The one branch that could in principle produce both is the
rewrite arm, where a kept model row would sit beside carried card
lines, and it cannot today because `store.rb:265`'s `kept` is
unreachable — see the non-goals. Promoting the four unrendered shapes
would retire the carry and make the separation structural rather than
circumstantial. Either way there is no invariant kept by proximity,
`with_birthday` leaves Store, and composition happens in one place
instead of at each read path.

Composition sits below the accessors, not only under `#vcard`.
`Admin::Format.birthday` finds a BDAY in `contact.properties`, prefers
`contact.birthday`, and falls back to `Birthday.from_value` for bare
properties and the raw value otherwise. Parsing the composed card keeps
every one of those arms behaving exactly as it does now — the composed
BDAY is found where it is today, the in-card unmodeled spellings still
fall through — so that method needs no change at all. That it needs
none is the check on the boundary being drawn in the right place.

## The contracts

`Contact.for(id:, stored:, birthday:)`, with `birthday:` required and
carrying no default. The class already argues this at `contact.rb:73`:
`.for` is the only constructor because "an etag that came from anywhere
but the card in hand is an etag that can be wrong." A birthday from
anywhere but the store is wrong the same way, and an optional `nil`
would let a caller quietly get no birthday off a card that has one.
Required is also what forces every call site to be looked at, which
matters because the parameter's meaning changes while its type does
not.

The parameter is `stored:` rather than `vcard:` for that reason — a
`vcard:` argument that is not what `#vcard` returns is a trap, and
`put` already names its local `stored`.

`#birthday` becomes a plain reader. `#vcard` composes lazily and
memoizes, `#etag` hashes it and memoizes, `#properties` parses it.
`initialize` narrows to `(id, stored, birthday)` and stops taking a
precomputed tag, since the composed card does not exist at
construction. The etag's derivation is unchanged, only deferred, so a
contact read back still hashes the same way one about to be written
does. Memoization is `return @x if defined?(@x)`, as in
`VCard#properties` and `#lines`.

Store deletes `with_birthday`; both call sites collapse to
`Contact.for(id:, stored:, birthday:)`.

## Nothing reaches the wire

The composed bytes come from the same `VCard#insert` over the same two
inputs, so they are identical octet for octet. Etags do not move, no
client refetches, there is no migration, and the change log is
untouched. `web.rb:595`'s strong-ETag test — `stored.vcard.to_s ==
vcard`, the one place composed bytes are compared against submitted
ones (RFC 6352 section 6.3.2.3) — keeps giving the same answer.

`rebuild_index` keeps reading raw rows through `VCard.new` rather than
Contact, which stays right because the index reflects stored cards and
no stored card carries a modeled BDAY.

## The Row that duplicated RecentContact

Separately and in its own commit: `Admin::ContactsIndex::Row` is
field-identical to `Store::RecentContact`, and `contacts_index.rb:36`
maps one into the other for nothing. `Row` goes, `RecentContact` is
rendered directly, and `matches?` is untouched because it reads only
`row.contact`.

This is the whole of the `updated_at` problem. Putting a timestamp on
Contact was considered and rejected: `store.rb:54` deliberately keeps
one off, and it would be the first genuinely storage-level field on a
class whose other fields are the contact or derived from it. The
duplication was never Contact's to fix.

## The cost, taken deliberately

Two related inputs mean a caller can pass a birthday that disagrees
with the card beside it, which the single-input constructor made
impossible. Nothing enforces the pairing but Store, the only production
caller.

The sharper loss is a self-check. Today `#birthday` reads the served
card, so the admin UI displays what a client downloads, and a broken
`to_line` would show up in both. After this, the UI shows the store's
truth while clients get whatever `to_line` emitted, and the divergence
is silent. `to_line` is ten lines with two arms and its unit tests pin
the correspondence, so the insurance was thin — but it is being spent,
not kept.

The test helpers at `test_contact.rb:20` and `test_format.rb:12` gain a
`birthday:` parameter, and the fixtures improve rather than merely
churn. Today they build a Contact from a card carrying
`BDAY:1985-12-10`, a shape no stored card ever has. After, the modeled
cases pass a BDAY-free card beside a `Birthday` and the fallback cases
pass a card carrying an unmodeled BDAY beside `nil` — both the
production invariant.

## Rejected alternatives

Store passing the composed card alongside the model, as above: one
fact, two homes, held by proximity.

An optional `birthday:` that falls back to parsing the card when it is
not passed. That is the loop again, reachable from any future caller
that forgets, and it makes the fallback the thing tests exercise while
production never does.

Keeping the loop until groups force it. Groups change the writer and
the composed set, not this constructor, so nothing about the shape gets
easier by waiting, and every surface added meanwhile is written against
the reader that has to change.

## Non-goals

- Promoting the four unrendered birthday shapes out of stored cards
  into the birthdays table. It is a migration with a client-visible
  consequence, and it turns on what a second client renders — the
  unrun probe in `kxyvsxzx`, "Probe the birthday shapes against iOS
  Contacts", whose render half already decides both what `to_line`
  emits and what a rewrite carries. Its own doc, gated on that. Note
  that `store.rb:265`'s `kept` branch already exists for it and is
  currently unreachable, since `write_birthday` only ever stores what
  `from_property` returned and migration 002 calls `from_property` too.
- Modeling new properties, or any change to the accessor set.
- The web editor. This is still the read half.
- Groups. This makes the reader groups-ready; it does not build them.
