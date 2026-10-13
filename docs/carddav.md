# The CardDAV surface

What the server answers on the wire, what a client needs from it, and
where to look when a client disagrees. The specifications themselves are
vendored in `docs/rfcs/`, whose README says what each one governs here;
what the Apple clients do off-spec is `docs/apple-contacts.md`.

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

## Outside the RFCs

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
