# Contacts on entities

2026-10-25. A plan to build, starting from main as of `wssqyqqp`. Every
card and every group becomes an entity. Addresses and notes move off
cards and group lines and onto the entity. The contact types are
shaped last, around the model, instead of first.

A first attempt at this went types-first. It split `Contact` into a
base that reads a card and a subclass that carries an entity, then
held the base instead of extending it, then extended it again, and
renamed the base three times. Meanwhile `Group` built a contact over
a borrowed id so it could read its own lines. Most of that churn came
from the group lines: types drawn around a model that was about to
change kept failing to fit. This plan changes the model first.

## Where main stands

`Contact` is the one model of what a contact says
(`docs/plans/2026-09-01-contact-is-the-model.md`). It reads a card as
rows, composes the served card from the stored card plus the group's
lent lines plus the birthday, and derives the etag. Nothing has an
entity. `Group#reading` builds a `Contact` over a group's lines to read
its addresses and notes. `ListedContact` wraps a `Contact` built from
the index and forwards its readers one by one, so that it never
answers an etag.

## The model

An entity is an id and nothing else. A card is the component that
makes an entity a contact, and a group row is the component that makes
it a group. Everything else belongs to one of two tiers:

| Piece | Lives in | Keyed by |
|---|---|---|
| Name, TEL, EMAIL, IMPP, PHOTO, and unmodeled properties | The card's stored bytes | Card |
| Birthday | `birthdays` | Card |
| Search and sort keys (derived) | `search_keys`, `sort_keys` | Card |
| Addresses, each with an optional label | An address component | Entity |
| Note, at most one | A note component | Entity |
| Tags | `taggings` | Entity |

A component goes on the entity only when either kind can carry it. A
group has no birthday, so the birthday stays on the card.

A group lends `ADR` and `NOTE` and nothing else
(`db/migrations/004_groups.rb`). With both on the entity, a group
lends nothing as a line, so `group_properties` goes away.

## Composition

The served card is the stored bytes, plus the card's birthday, plus
the addresses and the note of its own entity, plus the addresses and
the note of each group it belongs to. The note keeps the shape
`docs/plans/2026-09-25-one-note-per-contact.md` decided: one `NOTE`,
the member's own text first, then a labeled section for each group
that lends one.

A labeled address composes with an `item` group of its own, numbered
past every group the stored card already uses, so a lent label can
never pair with the member's own line.

Served bytes no longer match stored bytes for any card with an
address or a note. AGENTS.md opens by saying contacts are served as
the bytes that were stored, and that line needs rewording in the step
that lands this.

## Matching what comes back

An inbound `ADR` is matched the way `EditedContact#subtract_inherited`
matches a lent line today. The first pass strikes every lent address
that came back saying the same thing, along with its label line. The
second pass attributes what is left. A lent address with no candidate
of its name was deleted, and one with exactly one candidate was edited
to it. More than one candidate cannot be attributed. Every address
still unclaimed after both passes is one of the member's own and
replaces the member's own rows, in submission order. An address that
cannot be attributed lands there too, so an edit is never lost.

Matching ignores `item` numbers, because the Apple clients renumber
them freely (`docs/apple-contacts.md`). It pairs each address with its
label line the way `EditedContact#label_of` does.

A group's address carries a label like a card's. On main,
`EditedContact#shareable?` refuses a line with a property group in
front, because `group_properties` cannot hold one, so an Apple
client's `item1.ADR` edit to a lent address stays in the member's own
card. With a label column on the component, that edit reaches the
group.

`EditedContact#subtract_notes` reads the note sections back as it does
today, and a member's edit to a group's section writes the group
entity's note.

## The types

The types follow the model:

- `ContactDetails` is a composed card with no entity behind it: an
  import's preview, or a card on its way into the store. The caller
  hands over the addresses and the note, because components are keyed
  by an entity it does not have.
- `Contact < ContactDetails` is the same, with the entity's id, and the
  store fills in the components. Only the store makes one. The
  subclass is what lets the type checker keep an entity-less card out
  of the screens that link by entity.
- A `ContactReadings` module holds the readers over card bytes (name,
  nickname, sort, organization, TEL, EMAIL, and IMPP). `ContactDetails`
  and `ListedContact` both include it, which replaces the forwarding.
  Addresses and the note are read from components.
- `Group` reads its addresses and its note from its components. Nothing
  builds a contact over a group, and `GroupDetails` never needs to
  exist.

The name `ContactDetails` is provisional. Rename it in the step that
introduces the split, and nowhere else.

## Order of work

Each step builds and passes on its own:

1. Make every card a component of an entity (016). Mint the entity's id
   in `ChangeId`'s alphabet, separately from the card's href, because a
   client chooses the href and `Store#reid` moves it. Leave out a kind
   column, since the components already say what an entity is.
2. Make every group a component of an entity (017), re-minting group
   ids into the same id space and moving the group change log along.
   Use triggers to refuse an entity that holds both a card and a
   group, which a foreign key cannot express. Nest `create_group` in a
   savepoint, so a taken name inside `regroup` does not leave an
   orphaned entity behind.
3. Add the address and note components, move every `ADR` and `NOTE`
   out of `cards.vcard` and `group_properties`, and drop
   `group_properties`. Composition, `EditedContact`, search, and the
   group editor all read and write components from this step on.
4. Split `ContactDetails` from `Contact` and add `ContactReadings`.
5. Name contacts by entity in admin URLs, with `Store#card_id_of`
   resolving the card. A minted id is random, so tests ask the store
   for a contact's path instead of predicting it.

Steps 1, 2, and 5 match commits from the first attempt (`ptzpuumk`,
`noslypwz`, `rxnypqnm`, and `npylqowt`) and can be carried over. Steps 3
and 4 replace the five contact-type commits from `nmxstnny` through
`wplqnlok`.

## Gotchas from the first attempt

- Migrations 014 and 015 load the contact class by name to compute
  their keys, so renaming that class means editing both migrations.
- SQLite cannot add a foreign key to an existing table. Each step that
  rekeys a table rebuilds it and every table that references it,
  dropping children before parents. Renaming a parent aside first does
  not avoid the cascade, because with foreign keys on, a rename
  rewrites the children's references (016's comment has the details).
- An entity id is drawn once, and a collision raises. At 2^48 ids, a
  collision means the generator is broken, so retrying would hide a
  bug.

## Open questions

- The final name for `ContactDetails`.
