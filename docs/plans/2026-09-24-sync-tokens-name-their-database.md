# Sync tokens name their database

2026-09-24. A sync token now carries the id of the database that minted
it, so a token held against a replaced database is refused with the
410 that makes a client resync, rather than answered with a delta
computed against a history it never saw.

## What went wrong

The token was `http://pro-tacts/sync/<sequence>/<digest>` — the change
log's sequence and the book's digest, and nothing that said which
database minted it. Sequences are per-database counters, so any other
database with overlapping numbers would accept it: `rake dev` reseeds a
throwaway database on every start, to the same ctag every time, and a
dump restored onto the same machine replays a truncated history. In
both, a device's token at or below the new latest sequence passed the
route's guard and was answered with a delta from a log it had never
seen. Nothing errored. The divergence is silent and permanent: the new
log holds no entries for cards the old one deleted, so a client never
hears those removals and keeps serving them out of its cache forever.

This was found, not theorized: the per-user-books scenario testing
(2026-09-16, task `mny`) watched a client token from an earlier dev
session validate against a reseeded database and said so in a comment
— "a per-database value in the token would 410 it."

## The token

The spelling is now `http://pro-tacts/sync/<sequence>/<digest>/<database>`,
where the database half is `Store#database_id`: the first sixteen hex
digits of the SHA-256 of the change log's first entry — its `created_at`
alone. `SyncToken.read` takes the id, so a token not carrying this
database's gets the 410 with `DAV:valid-sync-token` the route already
sent (RFC 6578 section 3.2, marshalled per RFC 4918 section 16), and
the client takes the bootstrap path both clients were proven to walk
(task `mny`, scenario 6).

The id is derived, not stored. A reseed or a restore writes a new
first entry at a new moment, so every replaced database refuses every
token the old one issued. A live database's first entry never moves:
the log is append-only, no write touches a row's `created_at`, and
`Store#reid` — the one writer that rewrites a log row — moves only its
`card_id`, which is why the stamp is the digest's whole input.

Rejected on the way here:

- A minted id in a one-row table — correct, but a seventh kind of
  state: a migration, a mint-on-open, and a fact to keep out of the
  dump, all heavier than the bug it closes.
- The hostname, configured or off the request — it names the
  deployment, not the database, and both scenarios above happen on one
  machine under one name. It would also refuse the same database
  reached under a second name, a resync nothing asked for.
- A digest of the whole log — O(history) on every poll, and macOS
  polls.

## The costs

Every deployed device 410s once, at its first sync after this lands,
and bootstraps. That is unavoidable, not merely cheap: an old token
names no database, so there is nothing to check it against. Two edges
are accepted with it: a token taken from a book that was empty 410s
once after the first card lands, a resync of nothing; and two
databases first written within the same millisecond would share an id —
a coincidence no real replacement fits, and the price of deriving the
id rather than minting one.

## The fixtures

Recorded responses embed the token, so a replay book must answer as
the same database every run: `FixtureData.install(genesis:)` pins its
first change's stamp (`ExchangeFixtures::GENESIS`, year 2000 on
purpose), and the replay and `rake fixtures` both pass it. `rake dev`
seeds unpinned, so every dev start is a fresh id — which is the
original observation, now the behavior.
