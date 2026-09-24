# macOS exchange fixtures

Request-level recordings of what macOS Contacts (26.5.1,
AddressBookCore/2732.600.11) has sent to pro-tacts, promoted from the
exchange log as each session landed. Steps 01–09 are the read-only
exchange of 2026-08-14, the day the one-card milestone landed (see
`docs/plans/2026-08-12-one-card-on-macos.md`). Steps 10–11 are the
writes the client began sending once the collection advertised write
privileges, captured 2026-08-25. The requests are the baseline every
later response change is measured against.

Each step directory holds:

- `request` — the request line, the headers that affect routing
  (`Brief`, `Content-Type`, `Depth`, `If-Match`, `If-None-Match`,
  `Prefer`), a blank line, then the exact body, then a newline that
  ends the file and is not part of the body. `Authorization`, `Host`, `User-Agent`, and
  the `Tailscale-*` / `X-Forwarded-*` / `X-Mme-Client-Info` headers
  were stripped: they identify the tailnet and user, and the app
  ignores them.
- `response` — the status line, the significant response headers
  (`Content-Type`, `ETag`, `DAV`, `Allow`, `Location`), a blank line,
  then the exact body the app returned.

`request` files are evidence: edit them only when a new client session
supersedes this one. `response` files are a snapshot of current app
behavior: regenerate them with `rake fixtures` after changing responses
deliberately, and review the diff — accidental drift is exactly what the
comparison test exists to catch.

## The sync step

Step 08's request carries `http://pro-tacts/sync/1`, a token from before
tokens named the book they were issued for
(`docs/plans/2026-09-12-per-user-books.md`). The replay answers it with
410 and `DAV:valid-sync-token` rather than the 207 delta the recorded
session received.

Step 12 is a 410 the client really received, captured 2026-09-16 under
`rake dev` with the dev login switched so the token's digest named
another login's book. Its replay refuses it one step earlier: the
recorded token predates tokens naming their database
(docs/plans/2026-09-24-sync-tokens-name-their-database.md), so no part
of it names the replay book's database — the same 410 either way. After
the 410, macOS sent a ctag
PROPFIND, the Depth 1 listing, a GET for the one card it lacked, the
bootstrap PROPFIND, and a sync-collection report with the fresh token.
The listing and bootstrap match steps 06 and 09 byte for byte, and the
ctag PROPFIND differs from step 05 only in spelling CalendarServer
`C:` rather than `D:`, so none of them were promoted. iOS (26.6.2) sent
the same report apart from the token, took the same 410, and followed it
with a ctag PROPFIND, the listing, and a multiget for the card it lacked,
so `../ios-exchange` holds no step for it.

## The PUT steps

Both are the same edit to the same contact. Step 10 is the edit, which
replaces the seed card; step 11 is the client's retry minutes later,
byte-identical apart from `REV`, still carrying the etag of the
pre-edit card — so it fails its `If-Match`, which is what a lost
update has to look like.

Two liberties were taken promoting them:

- Step 10's `If-Match` was rewritten to the etag of the replay's seed
  card. An etag names server state, and the captured one names a dev
  database that no longer exists; the client's behavior — send back
  the etag the server last reported — is the part that is evidence,
  and it survives the rewrite.
- The seed carries that pre-edit card (`test/fixtures/cards/`), so the
  read steps list two contacts where the original session saw one.

The capture also lost the body's final newline — 835 bytes declared,
834 recorded — so the promoted card ends at `END:VCARD`. Captures with
`PHOTO` bodies (34 KB and 338 KB cards) were left unpromoted: possibly
real images, and the same code path as the 834-byte card that was.
Their wire shapes — the unfolded parameter section, the payload folded
at 76 octets a continuation — are built synthetically in
`test/photo_card.rb`, and a later session that set pictures on the
synthetic seed contacts deliberately (2026-09-04) is seeded directly
as `test/fixtures/cards/{photo,emoji,memoji}.vcf`; see
docs/apple-contacts.md, "Profile pictures".
