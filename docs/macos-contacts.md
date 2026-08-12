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
