# Milestone: one card on macOS

Get macOS Contacts to add a pro-tacts account over Tailscale and display a
single hardcoded contact. Nothing else.

## Why this first

Every later decision about storage, KDL parsing, groups, and sync depends on
knowing which parts of CardDAV macOS actually exercises. Guessing that from
the RFCs produces a server that is correct and still invisible to the client
— the failure mode behind most of the reports in
[monicahq/monica#4240][monica-4240]. A working end-to-end path turns those
questions into experiments: change one response, resync, observe.

[monica-4240]: https://github.com/monicahq/monica/issues/4240

It also fixes the network path early. Tailscale serve terminates TLS and
proxies to the app, which is exactly the arrangement that breaks
`/.well-known/carddav` redirects for everyone else (see
`../macos-contacts.md`).

## Capabilities

The server must satisfy, in order:

1. Discovery from a bare hostname: `/.well-known/carddav` leads to a
   principal that advertises an `addressbook-home-set`.
2. An address book collection carrying `getctag` and a
   `supported-report-set`.
3. A listing of that collection at `Depth: 1` returning one href and one
   etag.
4. The card itself, fetched by `GET` and by `addressbook-multiget`.

## Non-goals

Explicitly out of scope, to be built only after this milestone lands:

- Reading contacts from disk. The card is a string constant.
- KDL parsing and vCard generation.
- Writes of any kind: `PUT`, `DELETE`, `PROPPATCH`, `MKCOL`.
- Real etags and ctags. Constants are fine; the client only needs them to be
  present and stable within a session.
- `sync-collection`, `addressbook-query` filters, and multiple address books.
- Multiple users. One principal, one address book, one card.
- Authentication beyond whatever Tailscale provides.
- Reducing the responses to the minimal working set. Do the opposite for
  now: send what working servers send.

## Constraints

- vCard 3.0, with an Apple-shaped `PRODID`. See `../macos-contacts.md`.
- The `.well-known` redirect must be an absolute `https://` URL. A
  scheme-relative or `http://` redirect is dropped by the client without
  reaching the server.
- Whatever URL the account is configured with must answer the discovery
  `PROPFIND` at `Depth: 0` with `addressbook-home-set` present. Answering
  correctly but at the wrong resource ends discovery.
- `{http://calendarserver.org/ns/}getctag` on the collection is required, or
  no vCard is ever requested.

## Working loop

Nothing here can be validated from inside the repository. The only oracle is
Contacts.app on a Mac, and the agent doing the work cannot drive it. So the
loop is deliberately two-sided.

The agent changes one thing at a time, states what it expects the client to
do differently, and stops. Batching three response changes into one round
wastes the expensive half of the loop, because a single "still empty" cannot
say which change was wrong.

The human resyncs and reports back the raw evidence rather than a verdict:
the debug log for the exchange, the relevant lines from
`~/Library/Logs/CardDAVPlugin`, and what Contacts displayed. "It didn't
work" is not enough to act on; the request the client did or did not make
next is.

If a round produces no change at all, try removing the account and re-adding
it before concluding the change was wrong. Several reports of Monica
suddenly working describe deleting the account first, which suggests the
client holds onto discovery results — worth confirming for ourselves early,
since it decides how heavy each round of this loop is.

## Two logging modes

The evidence comes from pro-tacts' own logs, not from a proxy in front of
it. Reconstructing an exchange without a proxy needs method, path, `Depth`,
status, and the full request and response bodies — the client states its
intent in the `PROPFIND` body, so a log line without the body cannot explain
why the client stopped.

That volume is right for this milestone and wrong for everything after it,
so make it a setting rather than a decision:

- Normal logging is one line per request, no bodies. The default.
- Debug logging adds headers and full bodies on both sides. Off by default,
  switched on by configuration, and clearly the thing you turn on while
  sitting in the loop above.

Debug logging also conflicts with keeping contact data out of logs, which is
its own task. Keeping the two modes separate is what lets both be true: the
debug path can stay verbose because the only card is fictional, and the
normal path can be narrowed without taking the diagnostics away.

## Verification

Not a test suite — a real client on a real Mac:

1. Add the account in Internet Accounts with Account Type set to Manual and
   the bare Tailscale hostname as Server Address, Server Path empty.
2. The account saves without an "unable to verify" error.
3. Contacts shows the card.
4. The debug log shows the full discovery sequence and a request for the
   card, with nothing 404ing along the way.

Keep the debug log of the first fully working exchange. It becomes the
fixture set for the request-level tests that follow, and the baseline for
the later task of removing properties one at a time to find the real
minimum.

## Open questions

Answered 2026-08-14, when the milestone landed:

- Tailscale serve passes `PROPFIND` and `REPORT` through untouched. Every
  request in the debug log arrived with its method and body intact, and
  nothing was rewritten on the way back.
- The client accepts an account with Server Path empty. Discovery from the
  bare hostname completed and the card displayed.
- Nothing breaks when the same hostname serves both `/` and `/dav/`.

One deviation from the constraints above: `/.well-known/carddav` never
redirects for the client's `PROPFIND` — it answers directly with a 207,
which sidesteps the redirect-downgrade trap entirely. Only `GET` on it
redirects, and the client never issues one during discovery or sync.
