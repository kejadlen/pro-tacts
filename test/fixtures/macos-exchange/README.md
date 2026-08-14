# macOS exchange fixtures

Request-level recordings of the eight distinct requests macOS Contacts
(26.5.1, AddressBookCore/2732.600.11) sent to pro-tacts on 2026-08-14, the
day the one-card milestone landed — see
`docs/plans/2026-08-12-one-card-on-macos.md`. That exchange is the only
confirmed-working client session, so these requests are the baseline every
later response change is measured against.

Each step directory holds:

- `request` — the request line, the headers that affect routing
  (`Brief`, `Content-Type`, `Depth`, `Prefer`), a blank line, then the exact
  body. `Authorization`, `Host`, `User-Agent`, and the `Tailscale-*` /
  `X-Forwarded-*` / `X-Mme-Client-Info` headers were stripped: they identify
  the tailnet and user, and the app ignores them.
- `response` — the status line, the significant response headers
  (`Content-Type`, `ETag`, `DAV`, `Allow`, `Location`), a blank line, then
  the exact body the app returned.

`request` files are evidence: edit them only when a new client session
supersedes this one. `response` files are a snapshot of current app
behavior: regenerate them with `rake fixtures` after changing responses
deliberately, and review the diff — accidental drift is exactly what the
comparison test exists to catch.
