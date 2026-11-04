# A version marker guards a group's lines

2026-11-03. An iOS update re-pushed a phone's local address book, and
the member cards it uploaded — held from before the group had its
address, or re-serialized without it — read as deletions of the lent
line, which propagated to the group and took the household's address
off every member's card. The propagation itself is decided and stays
(docs/plans/2026-09-09-group-edits-propagate.md, "The open question,
decided"): a deletion must reach the group, or a shared address could
never be removed from a phone. What the decision lacked is proof that
the submission was composed from the group's current lines.

`If-Match` is not that proof. A PUT carrying no conditionals is
unconditional and allowed to proceed (`Web#write_card`), and a client
drops or mangles a line it cannot render (docs/apple-contacts.md, "A
birthday the client cannot render is dropped from the card"), so even
a current etag can front a card whose lines the client no longer
held. The proof has to travel in the card, and one form survives
both clients: a standalone property, kept byte-identical where
parameters are dropped and companions re-attach
(docs/apple-contacts.md, "An annotation survives only on its own
line").

## The marker

Composition adds one line per lending group:

```
X-PT-LENT:<group label>:<version>
```

The label names the group — the word the card already carries as its
note section's header, unique like a name
(db/migrations/008_group_names.rb) and stable across a seed, where a
minted id is not. Two groups sharing a label — a nameless group's id
and a group named the same — is the note split's own collision
(#report_indistinguishable_labels): the marker reads for one of them
what the other's line said, and attribution is refused on the
mismatch. Safe, and rarer than the notes case, which needs the same
collision.

The version is a SHA-256 over the lines the group lends, as it stores
them and in lending order, then the group's label. Over the stored
lines, because a group lends bare `ADR` and `NOTE` lines
(db/migrations/004_groups.rb) that compose byte for byte into every
member's card, so the stored lines are the state every member was
sent and the version names the same state from each of them. Derived
at composition and stored nowhere, the etag's own posture. It moves
when a line or the label moves and nothing else: a rename moves it
(the label heads the note section the client reads back), a reorder
moves it (every member's composed card moved), a rewrite that stores
the same lines in the same order does not.

## Arrival

The marker is composed like the lines it versions and never reaches
stored bytes. Every card on its way into the store sheds its
`X-PT-LENT` lines in `EditedContact`, which a client's PUT and an
import's write both reach through `Store#put`, so no arrival stores a
marker beside the one composition writes, and a marker for a group
that no longer lends is struck all the same.

## The guard

Pass one of the line matching (`EditedContact#subtract_inherited`)
is unchanged: a submitted line that says what a group lends is struck
rather than duplicated onto the member, marker or no marker. Pass two
— where a deletion and an edit are decided — runs only for a group
whose marker names the current version. Where the marker is absent,
stale, or unreadable, that group's rows are not editable by the
submission: no `GroupEdit` for it, and the lines that would have been
attributed its edit stay in the member's own card, the fallback an
unattributable line already takes. The misattributed edit is guarded
the same way — without a current marker, a stale card's one own
address can no longer be read as an edit of the lent line.

The note takes the same gate, section by section, since a `NOTE`'s
sections each name the group that lends them. A refused group's
absent section is not believed a deletion. Its edited section can
neither reach the group nor be spliced into the member's own note
without writing section grammar into it, so the whole value stays on
the member, the mangle bargain
(docs/plans/2026-09-25-one-note-per-contact.md, "The split") —
duplication rather than loss, visible, reported.

One report per PUT names how many lending groups were refused
attribution, carrying no card content, the arrival reports' own line.
It is the diagnostic the incident lacked: the wipe was silent,
because a successful PUT leaves no exchange entry
(docs/plans/2026-09-13-failed-exchanges-only.md) and the deletion
path raised nothing.

## What changes for clients

Every member of a lending group serves one more line, once, and its
etag moves with it: one resync round. A deliberate deletion still
propagates, from any client synced to the group's current lines —
the normal case, since syncing delivers the marker with the lines it
versions. A client that strips unknown properties — none known; both
clients keep them — loses only the ability to edit shared lines from
that client; the admin screens still can.

The member's own lines remain at the mercy of an unconditional
PUT, which is what an unconditional PUT means: what is guarded is
what propagates.

## Probes outstanding

Two things tests assert against this server's own composer and no
client has shown yet. iOS repositions a surviving standalone property
to the card's end, so an iOS round trip composes to the same value in
a different order and the PUT's strong etag costs one GET — harmless,
worth observing once. And the incident's own PUT, wherever it is
found in the instance's logs, becomes an exchange step
(`rake fixtures:extract`): a real markerless arrival, replayed
against the guard.

## Order of work

1. `Contact.lent_version`, the derived hash, and composition writing
   one marker per lending group, shed on both arrivals.
2. The guard in `EditedContact`, lines and notes together, with
   the report.
3. The store test for the incident itself: a markerless submission
   leaves the group's rows alone.
