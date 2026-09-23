# A change log for groups

2026-09-23. Groups get the history contacts have had since the change
log grew its diff: a `group_changes` table, one entry per write that
moved a group, rendered on the group's card the way the contact's
page renders its own.

## Why its own table

The cards' log (`changes`) is load-bearing for sync: its sequence is
the ctag and the number a sync token carries, and a sync-collection
report answers its entries as cards (RFC 6578 section 3). A group
entry in it would move the ctag on writes that change no card's bytes
— a rename moves nothing a client downloads — and an entry no card
backs would reach the report with nothing to answer it as. So a
second table, its own sequence, nothing synced from it.

What a group write does to cards is already logged where it belongs:
the fan-out writes a `group` entry for every member whose served
bytes moved, and for every card a `sync:` membership moved between
books. The new log is the other side of the same events — what
happened to the group itself — and the two record different facts
about one write, the way the etag and the diff in one card entry do.

## One entry per primitive, and only where something moved

Every group write path runs through six store primitives —
`create_group`, `rename_group`, `set_group_lines`, `add_member`,
`remove_member`, `delete_group` — including the composites
(`edit_group`, `edit_members`, `regroup`, `name_book`) and the
import's writes. Logging at the primitives logs everything once and
needs no composite-detail shape: an editor save that renames, moves a
line, and swaps membership reads in the history as exactly those
moves, in the order the transaction made them.

An entry is written only where the stored state moved. A rename to
the same name, lines rewritten identical, joining twice, leaving a
group never joined: no entry. This is deliberately the opposite of
the cards' log, which moves on a rewrite that stores identical bytes
— that bargain exists so a sync token never misses a change, and
nothing syncs from this log. Here a no-op entry would be a request
log, not a history. Both directions of the invariant hold: nothing
logged that didn't happen, nothing that happened left unlogged —
including a pure reorder of a group's lines, which the multiset diff
reports as an empty diff but which is a real entry, because the
lending order moved every member's composed card.

The actions are `create`, `rename`, `lines`, `join`, `leave`,
`delete` — the CHECK constraint's own list, as `Store::Action` is the
cards' four.

## What an entry carries

No etag: a group serves nothing, so there is no download for an etag
to describe (`Group#version` is a form guard, derived from what the
editor shows). What an entry carries instead is a `detail`, a JSON
object shaped by its action:

- `create`: the name it was created under, null for nameless.
- `rename`: `was` and `name`, either null — null being the one
  spelling of nameless (db/migrations/005_group_identity.rb).
- `lines`: the moved lines in the CardDiff spelling, `added` and
  `removed` — the same multiset difference, over the logical lines a
  group already stores its lines as (`CardDiff.between_lines`).
- `join`/`leave`: the card that moved.
- `delete`: a tombstone carrying the whole group — its name, its
  lines, its members — the card tombstone's own bargain: the entry is
  the only record left of what was here, the rows being gone.

The detail is action-shaped rather than a fixed column set because
the facts differ per action the way they do not for cards, where one
diff shape covers every write. It is stored as one JSON value for
CardDiff's own reason: displayed beside its entry, never queried.

`group_id` is an id and not a foreign key, the card log's reason: a
tombstone has to outlive the group it is about.

## The page

The group's card gets the contact page's third card, in its own
shape: a collapsed `details` under the members list — the history is
read after the thing that has one, and the members are part of what
the group is. The action sits in the type column; the moment and the
detail in the value column, the contact page's grid. A `lines` entry
renders the contact page's removed-then-added diff rows, which is
why the elide machinery moved from `ContactsShow` to `Format`: two
views now render diff lines, and a group can lend a NOTE as long as
any.

A join or a leave names the card that moved, linked to its page and
carrying its name, the members list's own bargain — the log is for a
person, and a person reads names. A card since deleted renders its
id plain, the tombstone's text being all that's left.

The log is left out of the dump with the cards' own
(docs/plans/2026-09-12-database-dump.md): what moved between
snapshots is the dump repository's own history.
