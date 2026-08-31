# pro-tacts

A CardDAV server for my family.

## Simplifying assumptions

- Small, trusted user group (2-3 people) — no permissions or access controls
- Network access via Tailscale — simple authentication
- Apple devices only (it might happen to work on other CardDAV clients, but
  only accidentally)

## Features it is being built for

None of these exist yet; they are what the design is shaped around. What
does work is under Status below.

- Groups with attributes (e.g., an address shared by all members)
- Selective sync (choose which contacts to sync rather than all-or-nothing)
- vCards exported to git after each write (version history, human-readable)

## Status

Serving real data, reads and writes both. Contacts live in a SQLite
database at `data/contacts.db` (override the root with `PRO_TACTS_DATA_DIR`, or the
database path alone with `PRO_TACTS_DATABASE`), one row per contact,
holding the vCard itself:

```
BEGIN:VCARD
VERSION:3.0
N:Smith;John;;;
FN:John Smith
TEL;TYPE=mobile:+1-555-1234
UID:john-smith
END:VCARD
```

Storing the card rather than a parse of it is what lets the server keep
properties it does not model, which RFC 6352 section 6.3.2.2 requires of
anything accepting writes; `docs/plans/2026-08-24-vcard-storage-and-groups.md`
makes the case at length. The same database holds the change log and
the birthdays — the two things in it that cannot be rebuilt, the
birthdays because a partial date has no vCard 3.0 spelling — and an
index of parsed properties, which can: `rake index:rebuild` derives
that again from the stored cards alone.

macOS Contacts displays them over Tailscale serve as of 2026-08-14, so
later work has a known-good baseline to change. See
`docs/plans/2026-08-12-one-card-on-macos.md` for what that milestone
established. A contact's etag hashes the card it serves and the
collection tags hash the membership, so a change to a card reaches synced
clients on their next poll. Writes arrive the same way: PUT stores the
submitted card verbatim (RFC 6352 section 6.3.2), and the change log the
sync tokens count on is written with it, in one transaction.

Requests are authenticated by the `Tailscale-User-Login` header that
`tailscale serve` injects, which it strips from incoming requests so a
client cannot forge one. A request without it gets a 403. That holds only
while the app is reachable through serve alone — bind it to localhost.
Tailscale documents two cases that carry no identity and so cannot get in:
Funnel traffic, which is public, and traffic from tagged devices.

Requests the server cannot answer — a 404, a refused report, or a crash —
are kept under `log/unhandled`, one directory per distinct request, in the
same layout as `test/fixtures/macos-exchange`. A client asking for
something unimplemented therefore leaves behind enough to implement it, and
the capture can be promoted to a fixture by copying it and stripping the
identifying headers.
Sentry gets the request body too, minus any card content, which
`ProTacts::SentryScrubber` redacts on the way out — hrefs and tailnet IPs
are not secrets, but the cards themselves never leave the machine.

## The minimal set macOS Contacts needs

The responses are the verified minimum for macOS 26.5.1 Contacts, found
by removing properties and re-provisioning until the card stopped
appearing (August 2026; per-round evidence in the task comments). This is
a per-client property, not a universal spec: iOS and other macOS versions
are untested and may need more — the fixture replay in `test/fixtures/`
is the harness to run when one of them misbehaves. What each response must
carry:

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
- `REPORT sync-collection`: `getetag` only — the client refetches changed
  cards through multiget or `GET` on its own.
- `GET` a card: the vCard body plus an `ETag` header.
- `PUT` a card: 201 for a create at an unmapped href, 204 for a replace,
  each carrying the strong `ETag` only when what is stored is what was
  submitted, octet for octet (RFC 6352 section 6.3.2.3) — a card whose
  birthday is subtracted out before storage and composed back in on
  read goes without the tag and the client refetches. A refused write
  is a 412 naming the precondition in a `DAV:error` body. The statuses
  follow the RFC rather than client evidence: no live write had been
  answered when they were written, so the first synced device to edit
  is its test.

Three properties are load-bearing in non-obvious ways, documented in
`docs/macos-contacts.md`: the collection's `resourcetype` (without
`card:addressbook` the client drops the account data), the
`sync-collection` advertisement (without it the warm sync never runs), and
`getctag` (without it no vCard is ever requested). Everything else the
client asks for — displayname, privileges, owner, quotas, push transports,
me-card, principal-URL, the multiget/query advertisements — is optional.

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

## What macOS Contacts needs

sabre/dav's [notes on the macOS Address Book client][sabre-osx] are the best
single source of client quirks, and they explain several failures that look
like protocol bugs but are not. See `docs/macos-contacts.md` for the details
worth keeping close, including how to turn on the client's own debug logging.

[sabre-osx]: https://sabre.io/dav/clients/osx-addressbook/

## Reference implementations

`servers/` holds compose files for CardDAV servers to compare against, each
sitting behind mitmproxy because those servers cannot be made to log what we
need. Point macOS Contacts at one, watch what it sends and what a working
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
