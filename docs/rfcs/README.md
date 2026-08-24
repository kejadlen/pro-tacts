# Vendored RFCs

The specifications this server implements, kept here so the code's
citations can be checked offline and so section numbers stay pinned to
the text they were verified against.

`lib/pro_tacts/web.rb` cites these by number and section next to the
handler that implements each one, and `lib/pro_tacts/vcard.rb` cites RFC
2426 for the card format.

| RFC | Title | What it governs here |
| --- | --- | --- |
| [4918](rfc4918.txt) | HTTP Extensions for Distributed Authoring (WebDAV) | PROPFIND, the Depth header, 207 multistatus bodies, `DAV:getetag` |
| [6352](rfc6352.txt) | vCard Extensions to WebDAV (CardDAV) | Address book collections, `addressbook-home-set`, multiget, `address-data` |
| [6578](rfc6578.txt) | Collection Synchronization for WebDAV | The `sync-collection` report and `sync-token` |
| [6764](rfc6764.txt) | Locating Services for CalDAV and CardDAV | The `/.well-known/carddav` bootstrap and its redirect |
| [5397](rfc5397.txt) | WebDAV Current Principal Extension | `current-user-principal` |
| [3253](rfc3253.txt) | Versioning Extensions to WebDAV (DeltaV) | `supported-report-set` only; no versioning is implemented |
| [3744](rfc3744.txt) | WebDAV Access Control Protocol | `current-user-privilege-set` and the privilege names in it; no ACL is implemented |
| [2426](rfc2426.txt) | vCard 3.0 | The card format itself; the version Apple clients speak |
| [6350](rfc6350.txt) | vCard 4.0 | Nothing here implements it; kept for comparison |

One property the server sends has no RFC. `getctag` is an Apple
CalendarServer extension in the `http://calendarserver.org/ns/`
namespace, and it is served because macOS Contacts polls it. RFC 6578's
`sync-token` is the standardized equivalent.

Fetch a copy with `curl -O https://www.rfc-editor.org/rfc/rfc6352.txt`,
substituting the number. These are the published Standards Track texts,
unmodified.
