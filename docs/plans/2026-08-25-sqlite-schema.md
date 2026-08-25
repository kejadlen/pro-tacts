# The contacts database

2026-08-25. The storage half of
`2026-08-24-vcard-storage-and-groups.md`, built. That record argued for
SQLite with the card in a column and said why; this one is the schema
that came out of it, and the six choices inside it that were not
obvious.

KDL is gone, and so is the code that read it. There is no import path:
the storage record already had the web UI owning creation and Monica
seeding the rest, and a renderer kept alive only to move one directory
once is a second contact format to maintain for as long as anyone
forgets to delete it. An existing `data/contacts` is migrated by
checking out the last commit that could read it, or not at all.

## What the tables are for

```
cards             id, vcard, created_at, updated_at
changes           sequence, card_id, action, etag, created_at
card_properties   card_id, position, property_group, name, value
card_parameters   card_id, position, name, value
```

Sequel defines them, in a migration under `db/migrations/`, and queries
them. The sqlite3 gem is still there, as the driver underneath it.
`Store#migrate` runs the migrator on every open, which on a current
database is one read of `schema_info`: cheap enough to leave in, and it
removes the deploy step everyone forgets.

The first two are authoritative. The last two are a projection of the
first, and `rake index:rebuild` derives them again from the cards alone,
which is the property the storage record leans on when it says nothing
is authoritative twice.

Groups, membership, and provenance are not here yet. They are the other
half of that record and nothing in this schema forecloses them.

## Four decisions

**The etag is computed, not stored.** The first cut of this schema had
an `etag` column on `cards`, reasoning that the task asks for a write
landing the card, its etag, and its change-log entry together, and that
groups would eventually make the served card differ from the stored one.
Both halves were wrong about where the etag belongs.

An etag is the hash of the card served, and that card is the row. A
column holding it is a second copy of a fact already present, and the
only thing a second copy adds is the chance of disagreeing — a card
written without its etag, by a repair or a later migration, serves a
stale one silently. It also left `Contact` with two constructors, one
deriving the etag and one trusting a column, where everything the server
actually served took the second path and nothing checked they agreed.

The etag that genuinely cannot be recomputed is `changes.etag`: what the
card hashed to at that write, when the card has since moved on. That one
is stored, in the table that cannot be rebuilt, which is the same rule
the rest of this schema follows. The atomicity the task asks for is the
log entry, and it is in the transaction.

Groups do not change this. The served card becomes stored plus
inherited, so the etag becomes a hash of more inputs, still all of them
in the database. What groups do change is cost: a `Depth:1` listing
returns an etag per contact and no bodies, so composing every card to
hash it stops being free. If that ever bites, the column comes back as
what it would have been all along — a cache, labelled as one, repaired
the way the index is.

**`changes.sequence` is AUTOINCREMENT.** SQLite reuses a bare rowid
after the highest row is deleted. A sync token is a promise that
everything above it is unseen, and a reused sequence number breaks that
promise silently: the client is told nothing changed. AUTOINCREMENT
costs a row in `sqlite_sequence` and buys monotonicity.

**Only the authoritative tables carry timestamps.** A card gets
`created_at` and `updated_at`; a change-log row gets `created_at` alone,
because it is written once and never touched again. The index rows get
neither. They are replaced wholesale every time a card is indexed, so a
stamp on one would say when the projection last ran and imply a history
the property does not have — the card's own `updated_at` is the honest
answer to when that data last changed.

SQLite writes them, not Ruby, so that rows written in one transaction
agree; there is no ON UPDATE, so a column default covers the insert and
`Store#put` stamps `updated_at` itself in the upsert. `updated_at` moves
on every accepted write, including one that stores identical bytes: it
records when the store last took a card, which is a different question
from when the card last differed, and the etag already answers that one.

**The change log is never pruned.** It grows by one row per write,
forever, and that is the choice rather than an oversight: a sync token is
a promise about everything above it, so the safe moment to drop an entry
is once every client has moved past it, and this server does not track
clients. At a family's rate of edits the table is measured in kilobytes
per decade. If it ever matters, the shape of the answer is a floor —
discard entries below a sequence number and refuse tokens older than it,
sending those clients through a full resync — not a size cap that
silently loses history a token still refers to.

**`changes.card_id` is not a foreign key.** A tombstone is about a card
that no longer exists; that is the whole point of it. The index rows do
carry a foreign key, with a cascade, because they should never outlive
their card.

**Writes nest.** SQLite has no nested transactions, and the fan-out the
storage record describes — one member's card rewriting its group and
every other member's card — is writes inside writes. Sequel's
`transaction` joins one already open rather than opening a second, so
`put` can be called from inside a larger write and the whole thing is
still one atomic unit. That behavior is the largest single reason the
store goes through Sequel rather than driving sqlite3 directly; hand
transaction nesting is exactly the kind of thing that looks fine until
the day half a fan-out commits.

## Parsing inverts

`vcard.rb` used to render KDL and raise on any key it did not know.
`VCard::Parser` now reads vCards and raises on almost nothing: a
property is a name, its parameters, and the text of its value, and it
does not care what any of them mean. That is what RFC 6352 section
6.3.2.2 asks for, and it is why the parse is a `StringScanner` over the
grammar in RFC 2426 section 4 rather than anything property-aware. It is
a class rather than a set of functions because the scanner is a position
that every step moves, and threading that through arguments only
disguises the state.

The strictness was right for what it guarded and wrong for this. A typo
in a hand-edited file is lost data; an unrecognized property in a stored
card is a client using the spec. It went out with the format it was
protecting.

What survived the renderer is `escape` and `fold`, which nothing calls
yet. They are the writer's half of `vcard.rb` and the next thing to
write — a PUT, or the web editor — needs both on its first line, so they
are kept and tested directly instead of being deleted and rewritten.
`unfold` sits with them rather than in the parser, because it is fold's
inverse and reads as one pair with it.

Parsing fails open. A card that will not parse is still served — the
bytes are in the column — it just contributes nothing to the index, and
`rebuild_index` returns the ids it could not read. Surfacing those to a
human is the web UI's job, not the store's.

## What the index does not do

Values are indexed as they are stored, still escaped, and not split on
the component separator. Unescaping is per-property semantics, and the
comparison the storage record needs for classifying a submitted card has
to normalize far more than that (see
`2026-08-24-corrections-from-the-first-write.md`) — it will do its own
normalizing, from the card, and would not have trusted a normalization
baked into the index anyway.

What the index does carry is enough to query on: property name and
value, parameter name and value, and the position that gives a repeated
property its only identity. Names are compared without case, because
`FN` and `fn` are one name and not two: RFC 6350 section 3.3 says so
outright for vCard 4.0, RFC 2426 does not say it in its own text, and no
client has ever meant them differently. Parameter values are compared
the same way for a blunter reason — Contacts uppercases them on every
card it touches, so case there is the client's habit rather than
anything a user typed.

## One thing Sequel is missing

`first` on a filter meant to identify one row will return one of several
without complaint, which turns a corrupted table or a filter that was
never as narrow as it looked into a plausible-looking answer.
`lib/sequel/extensions/sole.rb` adds `sole`, which raises either way it
is wrong: `Sequel::NoMatchingRow` — the error Sequel's own `first!`
raises — for none, and `Sequel::Sole::TooManyRows` for more. One method
rather than a nil-returning and a raising variant, because the two would
have been the same assertion written twice; a caller for whom no row is
ordinary says so by rescuing, which is what `Store#contact` does to turn
a missing href back into the 404 it is.

Its error message names the table and never the SQL. A filter can carry
card content, and an exception message is one of the things that reaches
Sentry.

## Two things Sequel makes awkward

The tables are `STRICT`, which admits only SQLite's own type names, and
Sequel's `String` is a `varchar(255)`. Every string column therefore
carries `text: true`. It is noise on each line and the alternative —
dropping `STRICT` — trades a column-by-column annotation for a table
that will quietly accept an Integer where a card belongs.

Values are literalized into UTF-8 SQL rather than bound, so a card that
arrived as ASCII-8BIT raises `Encoding::UndefinedConversionError` on the
first byte above 7 bits. `Store#text` relabels ids and cards at the edge.
Under the raw driver the same input failed differently and worse: it was
bound as a BLOB, which compares equal to nothing, so a card fetched by
the id it was stored under simply came back missing. Loud beats silent,
but neither is free, and the coercion has a test of its own.

## One store, not one per request

A single `Store` serves the whole process, with Sequel pooling the
connections behind it, the way the library expects to be used. Requests
read it; nothing in a route opens a database.

The first draft opened and closed one inside each request, which read as
prudence — a connection that does not outlive a request is one Puma's
threads cannot share — and was really just refusing to use the pool that
already solves that. It also meant a single request could open two, one
for the collection and one for the card, which is the tell.

The second draft made it a lazily memoized global, `ProTacts.store`, and
had `config.ru` touch it once at boot to force the migrations. Two things
were wrong with that. The boot line was a getter called for its side
effect, which reads like something safe to delete. And the memo it was
warming was `@store ||=`, which is not thread safe: eight threads racing
a fresh one built more than one store in twenty rounds out of twenty, so
the warm-up was not an optimization but the thing holding the race shut.

So the store is injected. `config.ru` builds it and hands it to the app
through `ProTacts::Web.store=`, which keeps it in Roda's own `opts` and
is therefore frozen along with the app — a write after that raises
rather than quietly taking effect. There is no global to race, migrations
run at boot where a bad one fails the deploy instead of somebody's first
request, and a test hands the app a throwaway store the same way. What
`Store.connect` is for is the other case: a database that is not the one
this process serves from.
