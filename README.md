# pro-tacts

A CardDAV server for my family.

## Simplifying assumptions

- Small, trusted user group (2-3 people) — no permissions or access controls
- Network access via Tailscale — simple authentication
- Apple devices only (it might happen to work on other CardDAV clients, but
  only accidentally)

## What it does

Contacts live in a SQLite database at `data/contacts.db` (override the
root with `PRO_TACTS_DATA_DIR`, or the database path alone with
`PRO_TACTS_DATABASE`), one row per contact holding the vCard itself.
Storing the card rather than a parse of it keeps the properties the
server does not model, which RFC 6352 section 6.3.2.2 requires of
anything accepting writes (`docs/plans/2026-08-24-vcard-storage-and-groups.md`).
What else the database holds that cannot be rebuilt is listed in
`Store`'s class comment; the rest is an index `rake index:rebuild` makes
again. `rake db:dump` writes the cards, birthdays, groups, and books out
as plain files under `data/dump` and commits them to that directory's
own repository, so a snapshot is something to revert to
(`docs/plans/2026-09-20-the-dump-commits.md`).

A group holds an address or a note written once and composed into every
member's card on the way out, with membership never exposed to the
client. A member editing a shared line in Contacts writes it back for
everyone (`docs/plans/2026-09-09-group-edits-propagate.md`).

Each user syncs a book of their own: the members of `sync:*`, which
everyone gets, and of `sync:<login>`. A book can be named in place of
the login, from `/setup` or with `rake book:name`, which renames its
group to `sync:<name>`. A card a client creates joins `sync:*`
(`docs/plans/2026-09-12-per-user-books.md`,
`docs/plans/2026-09-15-client-creates-join-everyone.md`).

The same app serves the admin screens: the contacts and groups and
their editors, `/setup` for a device's configuration profile, and
`/import` for saving a .vcf into the book contact by contact
(`docs/DESIGN.md`). Every pull request gets a Fly preview, and main
deploys one too, both serving the fixture book through `demo.ru`.

Requests are authenticated by the `Remote-User` header, which the proxy
in front of the app writes; a Caddy site's `header_up` overwrites
whatever arrived, so a client cannot forge it. A request without it
gets a 401. That holds only while the app is reachable through such a
proxy alone, so bind it to localhost. Tailscale traffic that carries no
identity, Funnel and tagged devices, cannot get in
(`docs/plans/2026-09-15-identity-from-one-header.md`).

DAV exchanges that go wrong (a status of 400 or more other than a 401, a
crash, or a report to Sentry) are written whole to `log/exchange.log`
under an id Sentry carries as the `exchange` tag, so an alert names the
exchange to read. `PRO_TACTS_DEBUG=1` logs every exchange instead. No
request body reaches Sentry, so the cards never leave the machine.

## The minimal set macOS Contacts needs

The responses are the verified minimum for macOS 26.5.1 Contacts, found
by removing properties and re-provisioning until the card stopped
appearing (August 2026). iOS 26.6.1 works with the same set; where it
sends something macOS does not is recorded in
`test/fixtures/ios-exchange/`. Other clients are untested, and the
fixture replay is the harness to run when one misbehaves. What each
response must carry:

- `PROPFIND /` and `/.well-known/carddav`: `current-user-principal` only.
- `OPTIONS` under `/dav/`: `DAV: addressbook` — the class 1, 3, and
  access-control claims are unnecessary — plus the `Allow` list.
- `PROPFIND` on the principal: `addressbook-home-set` only.
- `PROPFIND` on the address book collection: `resourcetype` (collection +
  addressbook), `supported-report-set` advertising `sync-collection`,
  `getctag`, and `sync-token`. At `Depth: 1`, member `getetag` entries —
  the collection itself needs no self-entry.
- `REPORT addressbook-multiget`: `getetag` plus `address-data` for each
  requested href.
- `REPORT sync-collection`: the members added, changed, or removed
  since the client's token — `getetag` only, removals as bare 404s —
  plus the new `DAV:sync-token`. A token the server never issued is a
  410 naming `DAV:valid-sync-token`, the client's cue to resync from
  scratch. The client refetches changed cards through multiget or `GET`
  on its own.
- `GET` a card: the vCard body plus an `ETag` header.
- `PUT` a card: 201 for a create at an unmapped href, 204 for a replace,
  each carrying the strong `ETag` only when what is stored is what was
  submitted, octet for octet (RFC 6352 section 6.3.2.3) — a card whose
  birthday is subtracted out before storage and composed back in on
  read goes without the tag and the client refetches. A refused write
  is a 412 naming the precondition in a `DAV:error` body.
- `DELETE` a card: 204, and the removal reaches other clients as a 404
  in their next `sync-collection`.

Three properties are load-bearing in non-obvious ways, documented in
`docs/apple-contacts.md`: the collection's `resourcetype` (without
`card:addressbook` the client drops the account data), the
`sync-collection` advertisement (without it the warm sync never runs), and
`getctag` (without it no vCard is ever requested). Everything else the
client asks for — displayname, privileges, owner, quotas, push transports,
me-card, principal-URL, the multiget/query advertisements — is optional.

sabre/dav's [notes on the macOS Address Book client][sabre-osx] are the best
single source of client quirks beyond this list, and they explain several
failures that look like protocol bugs but are not. See `docs/apple-contacts.md`
for the details worth keeping close, including how to turn on the client's own
debug logging.

[sabre-osx]: https://sabre.io/dav/clients/osx-addressbook/

## Protocol references

CardDAV is a stack of extensions rather than a single specification, so
implementing it means reading several RFCs together:

| RFC | Title | Why it matters |
|---|---|---|
| [4918][rfc4918] | HTTP Extensions for WebDAV | `PROPFIND`, `Depth`, `207 Multi-Status`, ETags |
| [3253][rfc3253] | Versioning Extensions to WebDAV | Defines `REPORT` and `supported-report-set` |
| [5397][rfc5397] | WebDAV Current Principal Extension | `current-user-principal`, the entry point to discovery |
| [6352][rfc6352] | CardDAV | Address book collections, `addressbook-multiget`, `addressbook-query` |
| [6578][rfc6578] | Collection Synchronization for WebDAV | `sync-collection` REPORT and sync tokens |
| [6764][rfc6764] | Locating Services for CalDAV and CardDAV | `/.well-known/carddav` and SRV-based discovery |
| [2426][rfc2426] | vCard 3.0 | The version Apple clients actually speak |
| [6350][rfc6350] | vCard 4.0 | The current version; Apple does not use it |

[rfc4918]: https://datatracker.ietf.org/doc/html/rfc4918
[rfc3253]: https://datatracker.ietf.org/doc/html/rfc3253
[rfc5397]: https://datatracker.ietf.org/doc/html/rfc5397
[rfc6352]: https://datatracker.ietf.org/doc/html/rfc6352
[rfc6578]: https://datatracker.ietf.org/doc/html/rfc6578
[rfc6764]: https://datatracker.ietf.org/doc/html/rfc6764
[rfc2426]: https://datatracker.ietf.org/doc/html/rfc2426
[rfc6350]: https://datatracker.ietf.org/doc/html/rfc6350

RFC 6352 requires an address book collection to support vCard 3.0 and treats
4.0 as optional, which is why contacts are rendered as `VERSION:3.0` even
though `docs/plans/2026-01-12-carddav-reference.md` shows 4.0 examples.

Two properties macOS depends on are not in any RFC. They come from Apple's
CalendarServer, which is archived but still the only written source:

- [`getctag`][ctag] in the `http://calendarserver.org/ns/` namespace, a
  collection-wide change tag. Without it, macOS never requests any vCards.
- [`push-transports` and `pushkey`][pubsub], for server-initiated refresh.
  Not needed, but macOS asks for them on every collection `PROPFIND`.

[ctag]: https://github.com/apple/ccs-calendarserver/blob/master/doc/Extensions/caldav-ctag.txt
[pubsub]: https://github.com/apple/ccs-calendarserver/blob/master/doc/Extensions/caldav-pubsubdiscovery.txt

## Reference implementations

A local `servers/` directory, ignored by git, holds compose files for
CardDAV servers to compare against, each behind mitmproxy because those
servers cannot be made to log what we need. Point macOS Contacts at one, watch what it sends and what a working
server sends back, then make pro-tacts match. pro-tacts itself is debugged
through its own logs instead.

Monica is the one confirmed working with macOS Contacts here, so prefer it
when a recording needs to be trustworthy. Its issue tracker is full of
reports of the opposite, which is worth knowing before taking them at face
value: the two recurring causes in [monicahq/monica#4240][monica-4240] are a
`/.well-known/carddav` redirect that downgrades HTTPS to HTTP, and Monica
requiring an API token rather than a password. Neither is a CardDAV problem.
The one genuinely protocol-level thread is the sabre/dav investigation that
issue prompted, [sabre-io/dav#1315][sabre-1315], on macOS giving up when
discovery answers at the wrong resource.

[monica-4240]: https://github.com/monicahq/monica/issues/4240
[sabre-1315]: https://github.com/sabre-io/dav/issues/1315

Two implementations are worth reading rather than running:

- [sabre/dav][sabre] is the reference PHP implementation and what Baikal,
  Monica, and Nextcloud are all built on. Its client-quirk documentation is
  more valuable than its code.
- [Xandikos][xandikos] is a small Python CalDAV/CardDAV server backed by a
  git repository, which makes it the closest existing thing to what
  pro-tacts is trying to be. Its
  [DAV compliance notes][xandikos-compliance] enumerate every method,
  header, property, and report against the RFC that defines it — a useful
  checklist for deciding what to skip.

[sabre]: https://sabre.io/dav/building-a-carddav-client/
[xandikos]: https://www.xandikos.org/
[xandikos-compliance]: https://github.com/jelmer/xandikos/blob/master/notes/dav-compliance.rst
