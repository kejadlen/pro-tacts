# A member's edit is the group's edit

2026-09-09. Task rzn, the third of the four
docs/plans/2026-08-24-vcard-storage-and-groups.md's group model needs.
The classification that task's second stage built starts acting: an
edited inherited line rewrites the line its group lends, a deleted one
takes that line away from the group, and both reach every other member
through the change log.

Until now `Store#subtract_inherited` could tell the four shapes apart
and moved a byte for only one of them. An edit or a deletion stayed in
the member's own card, deliberately, so that the edit would not be lost
while the propagation was unwritten. That is what changes here.

## The open question, decided

The 2026-08-24 plan left one thing open: whether deleting an inherited
property should propagate the way an edit does, or be suppressed for
that member alone through a tombstone table.

It propagates. The plan's own model has no per-member overrides —
"a member either inherits or does not, and membership is the only
lever" — and a suppression row is a per-member override wearing a
different name. A negative one is still one.

The blast radius that made the question worth asking is real: an edit
fixes a typo for everyone, and a delete takes the household's address
off three cards from a phone that offers no confirmation. What answers
it is not a second mechanism but the admin UI (task opy) — a group is a
record with a history, and its lines are recoverable from the change
log's diffs, which record the lines each write moved.

## What a propagated edit stores

The submitted line's own bytes, not the group's header with a new value
spliced into it.

The editor's surgical save does the opposite for a phone or an email:
it keeps `VCard.header_of` and swaps the value, because the form models
no parameters and rebuilding the header would drop the three TYPE
parameters macOS writes. A propagated edit cannot use that rule,
because a relabel is one of the edits it must carry. `Store#kept_types?`
reads `ADR;TYPE=home` coming back as `ADR;TYPE=work` as an edit on
purpose — "a member who relabels a lent address from home to work
edited the shared line as surely as one who changed a digit of it" —
and re-rendering that under the group's old header would propagate the
value and silently discard the label.

So the group takes the line as the client spelled it, which is also the
rule the group's rows already follow: what the author wrote is what a
member's card carries, down to the spelling this server would not have
chosen (db/migrations/004_groups.rb).

## The line a group cannot hold

`group_properties` admits `ADR` and `NOTE`, bare or parameterized, and
refuses a grouped spelling — `item1.ADR:` starts with neither `ADR:`
nor `ADR;`. That constraint now stands between a client and a 500.

The case is not hypothetical, and `Store#kept_types?` already documents
it: an address type Contacts has no field for comes back as an
`X-ABLabel` on a property group, taking the `TYPE` parameter with it,
on an address nobody touched. That reads as an edit, and propagating it
would put `item1.ADR:...` into a table whose CHECK refuses it — an
exception on an ordinary sync.

A candidate line the group cannot hold is therefore not propagated. It
stays in the member's own card, which is exactly where the old
behaviour left every edit, and reports through Sentry the way an
ambiguous attribution does. `Store::SHAREABLE_NAMES` is a second copy
of the CHECK's list and says so where it is defined: the constraint
stays the authority, and this is the pre-check that keeps a client's
relabel from being a crash rather than a refusal.

## The fan-out

A group edit moves bytes on cards nobody wrote to. Each of those
members needs a change-log entry or its client will never refetch —
"a client's sync token silently skips whatever the log missed".

The entry is the `group` action migration 004 widened the CHECK for,
carrying the member's newly composed etag and a `CardDiff` of the lines
the group edit moved on that member's served card. One per member whose
composed bytes actually moved, which is narrower than one per member of
the group: a rename moves nothing, a member joining a group that lends
nothing gains nothing, and an entry for either would spend every
client's next poll on a card that reads identically.

The writing member gets none. Its own `put` entry already carries the
composition, which is why `#put` applies the group's rows first and
composes its `Contact` afterwards — the etag a client's token is handed
has to be the hash of the card that write leaves behind, group line
included.

All of it inside the one transaction the member's own write already
opens. Sequel joins an open transaction rather than nesting it, which
is what lets the fan-out run from inside `#put` at all.

## Two edits, one shared value

`If-Match` protects the member's card and not the shared state behind
it: Alice's conditional passes while Bob's card changes underneath him.
Bob's etag moves and his client resyncs, which is correct. Two
simultaneous edits to one shared address are the case that is not —
both conditionals pass and the group takes the last writer.

The transaction has to serialize for the last writer to be a writer at
all. SQLite's default deferred transaction takes no write lock until
its first write, so two of these that each read the group's rows and
then write have one fail outright with `SQLITE_BUSY`: the busy handler
declines to retry a lock upgrade, because a retry there could deadlock.
`BEGIN IMMEDIATE` takes the lock at the start, which is what makes the
`BUSY_TIMEOUT` this store already sets apply to it. `Store#initialize`
sets Sequel's `transaction_mode` to `:immediate` for every transaction
the store opens; the writes here are all short, and a reader is
unaffected under WAL.

## Where the editor stands

`Admin::ContactsEdit` renders its rows off `Contact#own` and splices
`Contact#stored`, so no save it makes can copy a group's value onto its
member. The nickname was the one field reading the composed contact,
and now reads `own` like the rest. Nothing depends on which properties
a group may lend: widening `SHAREABLE_NAMES` is a schema decision, not
a hunt through the views.
