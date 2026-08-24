# vCard storage and group attributes

2026-08-24. Contacts stop being KDL files rendered to vCard on request.
The card a client sent becomes the stored form, groups contribute
properties to their members' cards at render time, and the database
holds what the cards cannot.

This supersedes the storage half of
`2026-01-12-carddav-architecture.md`. The URL structure, the RFC list,
and the discovery flow there still hold.

## Why the format has to change

Phase 2 adds writes, so Contacts.app can edit. That single change
invalidates KDL as the stored form, and it is worth being precise about
why, because the reason is not "we did not model enough properties."

RFC 6352 section 6.3.2.2 requires servers to keep what they do not
understand:

> Servers MUST support the use of non-standard properties and
> parameters in address object resources stored via the PUT method.

macOS Contacts leans on those heavily — `X-ABLabel` with `item1.`-style
grouping, `X-ABADR`, `PHOTO`, `REV`. Today `vcard.rb` models four node
types and raises on anything else, so a real card from the client would
either 500 the PUT or silently lose fields.

Modeling more properties does not fix it. Three different mismatches
hide behind "storage does not match the vCard", and only the first is
data loss:

| Mismatch | Example | Cost |
|---|---|---|
| Semantic loss | `X-ABLabel` dropped because it is unmodeled | The user's data is gone |
| Syntactic drift | `BDAY` re-serialized in a different valid form | Bytes differ, meaning does not |
| Deliberate divergence | A group's address injected into a member | Intended, see below |

Syntactic drift is where birthdays and notes land. RFC 2426 section
3.1.5 defines `BDAY` as "a single date value... It can also be reset to
a single date-time value", so `BDAY:1996-04-15` and
`BDAY:1953-10-15T23:10:00Z` are both legal. Parse either into a `Date`
and re-render, and the output may not be the octets that arrived.
`NOTE` drifts through folding instead: the 75-octet break points depend
on whoever folded the line.

Drift is cheap. RFC 6352 section 6.3.2.3 conditions its rule on octet
equality alone, and the penalty for failing it is that the PUT response
carries no strong ETag, so the client refetches the card. One extra GET
per save, at family scale, is nothing. Normalizing is allowed as long
as the response is honest about it.

Semantic loss has no such escape, and no schema avoids it: a structured
model cannot represent serialization choices at all. So model *and*
store, but store the document and derive the model.

## What holds the bytes

SQLite is the transactional store, with the raw card in a column.
`.vcf` files are exported to a git directory after each commit — a
mirror for history, backup, and inspection, not the store.

The deciding constraint is the change log. The parsed index can be
thrown away and rebuilt from the cards at any time; sync history
cannot, because "what changed since token X" is not recoverable from
current state. A card write must land atomically with its change-log
entry, its group fan-out, and its etag update, or a client's sync token
silently skips a change. Splitting cards into files puts that write
across two stores, and the unrecoverable half is the one at risk.

Exporting afterwards keeps the version-history feature without putting
git in the write path. No commits are issued from web requests, the two
writers (CardDAV and the web UI) do not have to serialize across two
stores, and a crash leaves the mirror stale, which self-heals on the
next export.

Nothing is authoritative twice:

| Data | Authoritative home | Rebuildable |
|---|---|---|
| Card data, minus inherited properties | The stored card | — |
| Groups, membership, shared attributes, provenance | Database | No |
| Parsed card fields for querying and the web UI | Database | Yes, from the cards |
| Change log, sync tokens, tombstones | Database | No |

That table is the invariant to protect. There is no sync layer between
the database and the cards, and if one is ever needed, something has
become authoritative in two places. What exists instead is a one-way
projection (cards to index, idempotent, safe to rebuild) and a
composition at request time.

## Groups compose into cards

Groups are server-side state. Membership is not exposed to the client
at all — no `X-ADDRESSBOOKSERVER-*` convention, no group cards. A group
holds attributes, and members inherit them transparently:

```
served  = stored + inherited
stored  = submitted - inherited
```

Those compose. Serve `S+I`, the client PUTs `S+I` back untouched,
subtraction returns `S`. Stable and idempotent.

The read path already works this way. `contact.rb` hashes the rendered
vCard rather than the file's bytes, so an etag over the composed card
is coherent. Change a group's address and every member's rendered
bytes change, so their etags change, so the ctag changes, and clients
resync exactly the affected cards.

Subtraction on write is the new work. Storing a submitted card verbatim
would materialize the group's address into the member's own card,
breaking the link so that later edits to the group reach nobody.

### Classifying what came back

Recompute what was last served — both halves are known — and diff the
submitted card against it. Each property that moved classifies by
where it came from:

| Change against last served | Meaning | Action |
|---|---|---|
| Inherited property, unchanged | Untouched | Store nothing |
| Inherited property, modified | Edit to the shared value | Update the group, fan out |
| Inherited property, absent | Deletion | Open question, below |
| Anything else | The member's own data | Store on the member |

An earlier draft identified injections by tagging them with a private
parameter, which section 6.3.2.2 explicitly permits. Diffing is
stronger: it does not depend on Apple preserving an unknown parameter
through a round trip, and it distinguishes "edited the shared address"
from "added a second address" where value comparison cannot. A marker
parameter is still worth carrying as a hint, but nothing load-bearing
should rest on it.

The schema needs provenance per injected property. When a member
belongs to two groups that each contribute an address, the diff says
which property changed, but only a recorded origin says which group to
update.

### Edits propagate to the group

A shared address is one thing seen from several cards, not a copy on
each. Editing it from any member's card updates the group, and the new
value reaches every other member. Fixing a typo in the family address
fixes it everywhere.

This removes per-member overrides from the model: a member either
inherits or does not, and membership is the only lever. "Everyone at
this address except the kid who moved out" means removing that member
from the group.

Two consequences to build for:

A PUT to one member's card rewrites the group and changes every other
member's rendered card, etag, and the ctag. That must be one
transaction, and the fan-out must enqueue change-log entries for all
members — the same fan-out an admin edit needs, now reachable from an
ordinary card write.

`If-Match` protects the member's card, not the shared state behind it.
Alice's conditional check passes while Bob's card changes underneath
him. Bob's etag changes so his client resyncs, which is correct, but
two simultaneous edits to one shared address both pass their checks and
the group takes the last writer. Serialize group updates inside the
transaction.

## Where KDL goes

Out. It existed because the stored form had to be hand-authorable, and
the web UI now owns creation. Import from the existing Monica instance
seeds the rest.

Monica import is a birth event, not a sync: Monica's model becomes a
vCard once, and from that moment the card is authoritative. Nothing
writes back, and nothing reconciles.

The web editor is a mutator, not a renderer. Creating a card from a
form is safe, because no prior octets exist to preserve. Editing one is
not: a form that round-trips through a struct discards every property
the form has no field for. Saving must apply a surgical change to the
stored card and leave untouched properties byte-identical, which means
the vCard layer needs a parse-preserving representation — properties
held with their original raw lines.

`vcard.rb`'s folding and escaping survive. Its KDL-shaped parts
(`NAME_COMPONENTS`, `ALLOWED_PROPERTIES`, `validate_children`) do not,
and its strictness inverts: raising on an unrecognized key is right for
a hand-edited format where a typo means silent data loss, and wrong for
stored cards, which must carry what they do not understand.

One task gets easier. "Fail open on parse errors" becomes nearly free —
a card that fails to parse can still be served, because the bytes are
right there. It just does not get indexed, which probably folds
"Surface contacts that failed to parse" into a web UI view.

## Open questions

Deletion of an inherited property is undecided. Propagating it is
consistent with edits, but the blast radius is not: an edit fixes a
typo for everyone, while a delete removes the address from everyone's
card and is easy to do by accident on a phone. Treating deletion as
suppression for that member instead needs a small tombstone table. The
two are separable — propagating edits without propagating deletes stays
coherent.

Five things rest on Apple's behavior rather than the specification, and
each is empirical:

- Whether Contacts attempts a PUT at all without the collection
  advertising `current-user-privilege-set`. This gates everything else.
- Whether Contacts handles an ETag-less PUT response gracefully.
- Whether it preserves unknown parameters through a round trip.
- What `X-APPLE-OMIT-YEAR` actually looks like on a birthday with no
  year. Recalled, not verified, and in no vendored RFC.
- Whether Monica can export vCards or speak CardDAV directly, which
  would remove the need to invent a field mapping.

The first four are answerable cheaply. `UnhandledRequests` already
captures 404s with full bodies, so pointing Contacts at the server and
saving an edit drops a real PUT into `log/unhandled` before any of this
is built.

## Non-goals

- The web UI's design. This covers only what it must not do to cards.
- Authentication changes. `Tailscale-User-Login` is unchanged.
- Multiple address books, multiple principals, `addressbook-query`.
- Selective sync, which filters which cards a client sees and does not
  modify any of them.
