# macOS Contacts as a CardDAV client

What the macOS Contacts client does, where it deviates from the RFCs, and
which failures look like protocol bugs but are not. Most of this is
distilled from sabre/dav's [client notes][sabre-osx] and from traffic
captures against the servers in `servers/`.

[sabre-osx]: https://sabre.io/dav/clients/osx-addressbook/

Scope: client behavior only. For the specifications themselves, see the
table in the README. For request and response shapes, see
`2026-01-12-carddav-reference.md`.

## Turn on the client's debug log first

macOS 10.8 and later will log its own CardDAV traffic once asked:

```sh
defaults write com.apple.addressbook.carddavplugin EnableDebug -bool YES
defaults write com.apple.addressbook.carddavplugin LogConnectionDetails -bool YES
```

Logs land in `~/Library/Logs/CardDAVPlugin`. This is faster than guessing
from server logs, because the client makes decisions (giving up, downgrading,
refusing a redirect) that never reach the server at all.

## The account setup path

The fastest path is a configuration profile: `rake profile:install` (with
`PRO_TACTS_HOSTNAME` set) first removes any installed pro-tacts profiles,
then renders `carddav.mobileconfig`, opens it, and
opens System Settings on the Profiles pane (via the
`x-apple.systempreferences:` deep link) — the profiles CLI no longer
supports installs, so the profile lands there as pending until you click
Install. That click is the whole manual step. `rake profile:remove` runs
the removal half alone via `profiles remove`.

The profile carries the hostname, fixed dev credentials, and SSL —
`CardDAVPrincipalURL` is deliberately omitted so the
account gets an empty Server Path, exercising discovery. Every render gets a
fresh identifier and UUIDs, so each install provisions a cold account with
no cached sync state — that is deliberate for the experiment loop, and
`rake profile:install` sweeping the old profiles first is what keeps it
cold. `profile:remove` finds them by scanning `profiles list` output for
the pro-tacts prefix. Apple's device-management
reference marks the CardDAV payload as allowing manual install, so no MDM is
involved.

The manual alternative, for cross-checking when the profile path misbehaves:
In System Settings, add the account under Internet Accounts, Add Other
Account, CardDAV account, with Account Type set to Manual. Manual matters:
automatic setup runs its own discovery and fails in ways that are harder to
read.

The Server Address field takes a bare hostname, no scheme. Reports of
working Monica setups differ on what belongs in Server Path — some use the
principal URL, some the address book collection, some leave it empty and let
`/.well-known/carddav` do the work. Leaving it empty is the case worth
supporting, since it is the only one that exercises discovery.

## The `.well-known` redirect is the most common failure

Nearly every "macOS can't see my contacts" report against Monica traces back
to `/.well-known/carddav`, not to CardDAV. The client will not follow a
redirect that downgrades HTTPS to HTTP, so a reverse proxy that terminates
TLS and then redirects using the request's own scheme sends the client to an
`http://` URL, which it silently drops.

Redirect to an absolute `https://` URL. Do not rely on the proxy passing the
original scheme through, and do not chain redirects.

## Discovery stops where the properties stop

macOS issues a `PROPFIND` with `Depth: 0` against the configured URL asking
for this set:

```xml
<A:propfind xmlns:A="DAV:">
  <A:prop>
    <B:addressbook-home-set xmlns:B="urn:ietf:params:xml:ns:carddav"/>
    <B:directory-gateway xmlns:B="urn:ietf:params:xml:ns:carddav"/>
    <A:displayname/>
    <C:email-address-set xmlns:C="http://calendarserver.org/ns/"/>
    <A:principal-collection-set/>
    <A:principal-URL/>
    <A:resource-id/>
    <A:supported-report-set/>
  </A:prop>
</A:propfind>
```

If the response comes back with `supported-report-set` filled in but no
`addressbook-home-set`, the client stops. It does not retry at a higher
`Depth`, and it does not walk the tree looking for the address book. This is
what [sabre-io/dav#1315][sabre-1315] documents: a well-formed 207 that
happens to answer at the collection instead of the principal reads to macOS
as "there is nothing here."

[sabre-1315]: https://github.com/sabre-io/dav/issues/1315

The practical rule is that whatever URL the account points at must answer
that `PROPFIND` with a usable `addressbook-home-set`.

## `getctag` gates everything after discovery

The client requires the proprietary `{http://calendarserver.org/ns/}getctag`
property on the address book collection. Without it, the client completes
discovery and then never requests a single vCard, which presents as an
account that connects successfully and stays empty.

## The collection must claim to be an address book

Discovery is not the only gate. After it, the client sends a `Depth: 1`
`PROPFIND` against the address book asking a long list of properties
(`resourcetype`, `supported-report-set`, `sync-token`, quotas, push — see
fixture `09-propfind-addressbook-bootstrap`). If the answer carries `getctag`
and `sync-token` but the collection's `resourcetype` does not include
`card:addressbook`, the client retries the `PROPFIND` once and then stops —
no `REPORT`, no card requests, an empty account. Verified by minimization
rounds 1–2 on 2026-08-17.

## Warm sync gates on the collection advertising its reports

An incremental sync (`sync-collection` REPORT with a stored token) only
happens if the collection's `PROPFIND` answer advertises `sync-collection`
in `supported-report-set`, per RFC 3253 report discovery. Without the
advertisement the client does not fall back or rescan — it simply polls,
sees the ctag, and never fetches, which presents as changes silently not
arriving. A cold account does not hit this: first sync uses the etag
listing plus `multiget`, which needs no advertisement. Verified by
minimization rounds 3b/3c on 2026-08-18.

## Writes are gated on the advertised privilege set

The client asks for `DAV:current-user-privilege-set` on the collection in
every `Depth: 1` poll, and attempts no write at all while the server omits
it. Adding it — `read`, `write`, `bind`, `unbind` (RFC 3744 sections 3.1,
3.2, 3.9, 3.10) — produced a `PUT` within a second of the first response
that carried it, from an edit made four hours earlier.

The `Allow` header is not what decides this. Contacts sends `OPTIONS` to
the principal, never to the address book collection, so it never learns
which methods the collection accepts. Verified 2026-08-24.

## Pending writes queue indefinitely and retry on their own

An edit made while the server refuses writes is not lost. `REV` is stamped
at edit time and the client replays that same body for hours, retrying
every few minutes, byte-identical apart from a refreshed `REV`. An
experiment round that fails for server-side reasons does not need the edit
redone — fix the server and the queued write arrives by itself.

## What a write looks like on the wire

Creates carry `If-None-Match: *` (RFC 6352 section 6.3.2) and a
client-minted UUID in both the request URI and the card's `UID`. The
16-character id scheme in `plans/2026-01-12-carddav-architecture.md`
therefore governs only cards this server creates.

Updates carry `If-Match` with the server's strong etag, so conditional
requests work and an etag derived from the rendered card is a usable basis
for them. Both use `Content-Type: text/vcard; charset=utf-8`.

## The client rewrites every card it touches

A card served by pro-tacts and edited in Contacts does not come back in the
form it was sent. Values survive exactly; serialization does not:

```
TEL;TYPE=mobile      ->  TEL;type=CELL;type=VOICE;type=pref
EMAIL                ->  EMAIL;type=INTERNET;type=pref
ADR;TYPE=home        ->  ADR;type=HOME;type=pref
(TEL before EMAIL)   ->  (EMAIL before TEL)
                     ->  PRODID and REV added
```

Parameter names are lowercased, values uppercased, defaults filled in, and
properties reordered. The phone number, address, and all seven `ADR`
components return byte-identical, including the two leading empty ones.

`TYPE=mobile` is not a valid value — RFC 2426 section 3.3.1 lists home,
msg, work, pref, voice, fax, and cell — so the rewrite to `CELL` is the
client correcting the server. The repeated `type=` spelling is sanctioned
by that same section, which allows either a parameter list or a value list.

The practical consequence is that any comparison between a card the server
sent and the card that comes back has to be semantic. Comparing bytes
reports every untouched property as modified. Verified 2026-08-24.

## Birthdays without a year

A birthday entered as a month and day carries Apple's own parameter, using
1604 as a sentinel in both halves:

```
BDAY;X-APPLE-OMIT-YEAR=1604:1604-01-01
```

A birthday with a real year is a plain `BDAY:1900-01-01`. Parsing either
into a date type loses the distinction and re-renders the no-year case as a
birthday in 1604, so the parameter has to survive storage rather than be
interpreted.

## One address book per account

Through at least macOS 10.10, Contacts binds one address book per account
and hides the rest. Later versions are better, but a design that assumes one
collection per account avoids the question entirely. This suits pro-tacts,
where a user has one address book anyway.

## vCard 3.0, not 4.0

Apple clients emit and expect vCard 3.0 ([RFC 2426][rfc2426]) with
`PRODID:-//Apple Inc.//macOS .../EN`. RFC 6352 requires address book
collections to support 3.0 and makes 4.0 optional, so serving 3.0 is
compliant, not a compromise.

[rfc2426]: https://datatracker.ietf.org/doc/html/rfc2426

## Smaller traps

- Usernames containing `@` are not percent-encoded by older clients, so
  email-address usernames break. Avoid them.
- The `me-card` property (`http://calendarserver.org/ns/`, set on the
  address book home) is expected; sabre notes crashes when it is missing.
- Older clients wanted the server at the domain root, and sometimes needed
  an explicit port. Worth remembering only if something inexplicable shows
  up on an old machine.
- One report describes the client probing ports 8443 and 8843 unprompted,
  and making an unauthenticated request before retrying with credentials.
  Expect a 401 round trip on every request.

## Reference implementations to compare against

`servers/` runs Baikal, Radicale, and Monica behind mitmproxy, because those
servers cannot be made to log what we need. Monica is the one confirmed
working with macOS Contacts here. When pro-tacts and a working server
disagree, the diff between two recordings of the same client action is the
fastest way to find out why.

pro-tacts itself is debugged through its own debug logging mode rather than
through a proxy.
