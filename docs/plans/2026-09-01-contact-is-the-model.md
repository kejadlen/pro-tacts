# Contact is the one model of a contact

2026-09-01. One contact is modeled in three places: `Contact` (id,
vcard, etag) for CardDAV, `Birthday` for the one structured field the
store composes into a card on read and subtracts on write, and
`Admin::ContactFields`, which re-parses the served card from scratch
for the UI. This folds the third into the first. Contact keeps being
the bytes CardDAV serves and becomes the structured read every
surface gets from one object; ContactFields goes away.

From review on PR #3 (Read-only admin Contacts view). Sketch only —
nothing here is implemented yet, and the accessor names are
suggestions the implementation may settle differently.

## What is actually duplicated

Store composes a birthday into the served card; ContactFields parses
it back out. The round trip works only because ContactFields knows to
ask `Birthday.from_property` about the two spellings `Birthday.to_line`
writes — the UI re-deriving, by parsing, a structured fact the store
held before it composed it away. Each new surface repeats the pattern
(search already builds a ContactFields per row), and each new
structured field would deepen it. The etag already records this design
virtue: everything about a contact derives from its bytes. The
structured read should too.

## The shape

Contact grows accessors over one parse of its own card:

| Accessor | Semantics |
|---|---|
| `properties` | The card's properties, parsed once and memoized — the substrate below |
| `name` | FN's value, unescaped (RFC 2426 section 3.1.1) |
| `name_components` | N's five components, split (section 3.1.2) |
| `phones` | Each TEL as value and type (section 3.3.1) |
| `emails` | Each EMAIL as value and type (section 3.3.2) |
| `addresses` | Each ADR as its seven components, not display lines (section 3.2.1) |
| `birthday` | `Birthday?`, via `Birthday.from_property` (section 3.1.5) |
| `notes` | The card's first NOTE, unescaped (section 3.6.2) |

Values come back in text form — unescaped — not wire form. The
accessors are deliberately shallow, like the parser: a card can carry
properties no accessor knows, and CardDAV still serves every one.

`properties` is the escape hatch for those. A served card can carry a
BDAY the model does not recompose — the spelling `subtract` kept
byte for byte, per RFC 6352 section 6.3.2.2 — and the admin view
keeps showing it as stored by reading the substrate when `birthday`
is nil. That is the layering: bytes, then properties, then typed
accessors, and a view reads the highest level that answers it.

## Everything derives from the bytes

No birthday is passed in. Store composes; Contact parses back what
compose wrote. That is sound because the two served forms are exactly
the forms `from_property` accepts — `to_line` and `from_property` are
inverse on them — so parsing the served card always recovers the model
the store held. Store could instead hand Contact its Birthday
directly, but then structure stops being derivable from bytes, one
fact has two homes, and every future composed field (groups) adds
another constructor input. One constructor, everything derived, is
the same virtue the etag already has.

## Contact stops being a Data class

Data freezes its instances, and a memoized parse needs an ivar. A
regular class keeps `Contact.for` as the only constructor, keeps the
id check and the derived etag, and gains a place to hang the parse.
The signature moves from `sig/pro_tacts/contact.rbs` to inline `#:`
comments, since the Data-class limitation is the only reason the sig
file exists (see docs/plans/2026-08-20-type-checking.md). Value
equality becomes identity; nothing relies on the former today.

The parse is lazy, and that is load-bearing rather than style:
`Store#ctag` and both listing reads build a Contact per row and never
read structure, so an eager parse would tax every sync check with a
parse nothing uses. Lazy, the costs match today exactly — a UI render
parses once, a CardDAV path never does.

A card that will not parse still raises from the accessors, the same
stance `ContactFields.from` takes: PUT validates before storing, so
an unparseable stored card is corruption, and Sentry is where that
surfaces. Serving is unaffected — the CardDAV paths answer in bytes
and never call an accessor.

## Presentation stays in the views

What ContactFields knows as formatting is not structure and does not
move into Contact. Initials (N-aware with the FN fallback), the
two-line address shape, rendering April 12, type-label defaults —
these move into the admin views and `Admin::Format`, which both views
already share. The parsing half of ContactFields moves into Contact;
the presentation half dissolves into the views; the class is deleted.

## Why this does not wait for groups

The open question on the task: sketch now, or wait until groups or
editing forces the shape, since groups' shared and inherited
properties are structured state too. Groups get a say over the
writer, not the reader. On the read path a group composes properties
into the served card in Store, beside `Birthday.compose`; Contact
parses what it is handed; the accessors see member-and-inherited
merged, which is exactly what displaying one contact wants.
Provenance — which property came from which group — enters at write
time, in the diff-against-last-served the groups plan already
specifies, and lives in the store's transaction layer. If the admin
UI ever wants to *mark* an inherited property, that is Store's
knowledge to expose alongside Contact, not Contact's to hold. The
reader is groups-invariant, which is why sketching it now is safe.

## The writer half stays separate

Editing renders its form from these accessors — a write wants the
same structured view a display does — but saving must not round-trip
through them. The groups plan requires surgical edits over a
parse-preserving representation, properties held with their original
raw lines, because a structured round trip drops every property the
form has no field for. Two representations, deliberately: typed
views to read, raw lines to write. Conflating them is how data gets
lost. This plan builds the reader and starts nothing of the writer.

## Rejected alternatives

Parsing per accessor call, keeping Data, would re-parse the card
several times per render — worse than the ContactFields it replaces,
and the from-scratch re-parse is the smell this exists to remove. An
eager parse in `Contact.for` taxes `ctag` and the listings, as above.
Passing structured inputs in trades one derived fact for two homes,
as above. Waiting for groups defers a reader that groups cannot
change.

## Non-goals

- Modeling new properties. The accessor set is what the UI shows
  today; adding a property is a real decision, unchanged by this.
- Any change to Store, the etag, the ctag, or the CardDAV paths.
- The web editor. This is its read half, not its write half.
