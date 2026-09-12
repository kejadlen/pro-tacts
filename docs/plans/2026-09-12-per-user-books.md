# Per-user address books

2026-09-12. Each tailnet user syncs one address book holding only the
contacts selected for them, instead of every client seeing every card.
There is still one book per user, created by nobody: no MKCOL, and no
second collection.

## What a book holds

Selection rides on groups. A card in the group named `sync:*` is in
every user's book, and a card in `sync:<name>` is in that one user's.
A user's book is the union of the two, so group membership is the whole
selection model. A card in neither is in nobody's book and is still
shown in the admin UI, which remains one shared view for everyone.

The admin UI does not stop one user from editing another user's
`sync:` group. Getting onto the tailnet is the access control, as it
was before this change.

`sync:` names are unique (db/migrations/007_sync_names.rb), because a
client's create has to join exactly one group. Other names may repeat.

## Whose name

The name is the display name `tailscale serve` sends as
`Tailscale-User-Name`, such as "Alice Architect", not the login. Serve
encodes both headers with Go's `mime.QEncoding` (`encTailscaleHeaderValue`
in tailscale's `ipn/ipnlocal/serve.go`), so a non-ASCII value arrives as
RFC 2047 encoded-words and `TailscaleAuth` decodes it. A request with
either header missing or undecodable gets a 401.

A display name is not an identifier. Tailscale does not promise it is
unique or stable, so the following are true:

- Two users with the same display name share a book.
- A user who renames themselves moves off their `sync:` group until
  someone renames the group to match.
- A user can set their display name to match someone else's and sync
  that person's book.

These were accepted in exchange for group names a person can read. The
login would have avoided all three.

## The wire

The URLs do not change: `/dav/principal/` and `/dav/addressbook/` serve
the book of whoever is asking, which is the architecture plan's "user
identity from auth, not URL path". A card outside the requester's book
is not a member of their collection, so a GET, PUT, or DELETE on it is
a 404 and a multiget lists it as missing.

A PUT that creates a card adds it to the writer's `sync:<name>` group,
creating the group if needed, in the same transaction as the card.
Without that, a card created on a phone would drop out of the phone's
own book on the next sync. A DELETE still removes the card for
everyone.

The ctag stays the change log's global sequence. A change to a card in
someone else's book moves it too, which costs a sync-collection report
that finds nothing, never a missed change.

The sync token is `http://pro-tacts/sync/<sequence>/<digest>`, where the
digest is the first 16 hex digits of the SHA-256 of the display name. A
token whose digest is not the requester's gets 410 with
`DAV:valid-sync-token`, so a renamed user resyncs from scratch instead
of receiving a delta computed against a different book. A token in the
old `http://pro-tacts/sync/<sequence>` form gets the same 410. The
recorded macOS session sends one at step 08, so that step's replayed
response is a 410 rather than the delta the real client received.

## The change log

A sync token sees only what the log records, and a card entering or
leaving a book changes no bytes: a `sync:` group lends nothing. So a
change to `sync:` membership is logged as a `group` entry for each card
it moves, whether or not the card's bytes changed. That covers:

- a card joining or leaving a `sync:` group
- a rename where either name starts with `sync:`, which moves every
  member

A delta answers each logged card from the requester's book as it is
now: a card in the book is reported as changed (RFC 6578 section
3.5.1), and a card not in it is reported as removed (section 3.5.2).
The delta cannot tell a card that left the book from one that was never
in it, so the second kind is also reported as removed. A client drops a
removal for an href it never held.
