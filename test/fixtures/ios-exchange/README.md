# iOS exchange fixtures

Request-level recordings of what iOS Contacts (26.6.1, dataaccessd/1.0)
has sent to pro-tacts, from the session of 2026-09-08 — the first run
against a phone, after `/setup` installed the configuration profile.
The file format is `../macos-exchange/README.md`'s, and so is the rule
that `request` files are evidence and `response` files are a snapshot
`rake fixtures` rewrites.

This directory is not a second baseline. It holds only the steps where
iOS sends something macOS does not, so the whole of it is differences:

| Step | What differs from macOS |
|---|---|
| 01-propfind-principal | Namespace prefixes: `D:` is CardDAV and `C:` is CalendarServer, the reverse of fixture 04's |
| 02-propfind-addressbook-ctag | `C:` is CalendarServer, where fixture 05 uses `D:` |
| 03-propfind-addressbook-bootstrap | `D:` is CardDAV, `E:` is me.com, `F:` is mobileme; fixture 09 spells the same three `B:`, `D:`, and `E:` |
| 04-report-multiget | `D:` is CardDAV, and the request carries no `Brief`, `Depth`, or `Prefer` — all three of which macOS sends on the same report (fixture 07) |
| 05-put-contact-edit | The card is grouped: `item1.EMAIL`, `item2.TEL` with its `X-ABLabel`, `item3.ADR`. macOS sends the same three properties ungrouped, and an `X-ADDRESSING-GRAMMAR` iOS omits |
| 06-delete-contact | DELETE, which macOS has never sent |

`D:` meaning CardDAV in one client and CalendarServer in another is the
reason these steps are worth replaying: a prefix is arbitrary, and code
that reads one as a name breaks on the client that spells it
differently. Nothing here should ever be "fixed" to match macOS.

The steps run in order against one store, so 05 edits the card 06 then
removes.

## Provenance

Two things were taken from the capture rather than left as recorded:

- Step 04 asked for all nineteen seed cards. It is recorded with the
  one href fixture 07 uses, so the two multigets differ only in the
  prefix and the missing headers — which is the whole point of keeping
  it.
- The bodies are read back from `log/dev.log`, which logs a request
  line by line, so a body's final newline is not recoverable from it.
  Step 05's card ends at `END:VCARD`, the same shortfall the macOS PUT
  steps carry.

Step 05's `If-Match` needed no rewrite, unlike the macOS PUT steps':
`rake dev` seeds from `test/fixtures/cards`, so the etag the phone sent
back is the one the replay's seed card hashes to.
