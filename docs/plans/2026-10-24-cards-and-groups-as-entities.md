# Cards and groups as entities

2026-10-24. Not a plan to build. This records a refactor that was
weighed and set aside: storing cards and groups as entities in the
style of an entity-component system (ECS), where something that
applies to both kinds is a component either kind can carry. A tag
that applies to people and to households raised the question. The
cheaper shape described below covers that case, and the refactor
waits until a second cross-kind need shows up.

## What prompted it

The book needs tags, and an xmas tag has to apply both to
individuals and to groups. Its list is one row per addressee. A
tagged group gives its name and the `ADR` it lends, and a tagged card
gives its `FN` and its own `ADR`. Nothing is copied onto the tag.
Once something applies to both cards and groups, the next question
is whether the store should treat the two as one kind of thing.

## What the refactor would mean

Every card and every group becomes an entity, which is just an id.
Everything else is a component table keyed by entity id: a name, an
address, lent lines, members, a photo, a birthday, tags. CardDAV
composition, the search index, and the xmas list become systems, each
a query over the entities that carry the components it reads. A tag
stops being special and becomes one more component.

## What already looks like this

Groups are split into components already. `groups` holds the name,
`group_properties` the lent lines, `group_members` the members, and
`group_photos` the photo. On the card side, `birthdays`,
`search_keys`, and `sort_keys` are component tables keyed by card id.
The card itself is the exception.

## Why a card does not decompose

A card is served as the bytes that were stored (AGENTS.md;
`docs/carddav.md` and `docs/apple-contacts.md` give the evidence).
Its name and its addresses live in those bytes. A group's name is a
column. So a name component would have two sources. For a card it
is derived, and `card_properties` is an index rebuilt from the bytes.
For a group it is the record itself. A system that reads names reads
both sources whether or not the schema calls them one component. The
refactor would put that split behind a view, not remove it.

## What it would cost

- One id space. A group id is four letters from k to z (migration
  005). Nothing in `cards` constrains a card id's shape, so a card
  and a group could share an id. An `entities` table would need the
  kind in its key, or ids prefixed by kind.
- Rebuilt foreign keys. Every table that references `cards` or
  `groups` (`card_properties`, `card_parameters`, `birthdays`,
  `group_members`, `group_properties`, `group_photos`, `search_keys`,
  `sort_keys`) would point at `entities` instead. SQLite cannot alter
  a foreign key, so each table is rebuilt, children dropped before
  their parent, the way migration 005 did, and over whatever the
  deployed database holds by then.
- Two change logs. `changes` is per card, and every client's sync
  token counts on it. `group_changes` is per group (migration 011).
  Merging them into one log per entity changes what a sync token
  means.
- The code. `Contact`, `Group`, `ListedContact`, `ListedGroup`, and
  their RBS are each built around one kind, and most of the 1,500
  lines of `store.rb` would move.

## The cheaper shape

Tags need two things across both kinds, and neither needs the
refactor:

- `taggings(tag_id, card_id, group_id)`, with a CHECK that exactly
  one of `card_id` and `group_id` is set.
- An `addressees` view joining groups (name, lent `ADR`) with cards
  (`FN`, `ADR` from `card_properties`). The xmas list reads it. It is
  one migration and rebuilds no table.

## When to revisit

When a second or third component applies to both cards and groups.
Each one would copy the exactly-one CHECK and add another branch to
the view, and after a few of those an `entities` table costs less
than the copies do. The role from task qtkwsunn (name the role a
contact plays in a group) does not count: it sits on the membership
edge, not on either kind.
