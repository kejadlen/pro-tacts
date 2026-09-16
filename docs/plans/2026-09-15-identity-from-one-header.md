# Identity from one header

2026-09-15. A request's identity is one login, read off one request
header the deployment names. It replaces the pair of Tailscale headers
and the display name that keyed a book.

## What went wrong

The deploy at `https://contacts/` sits behind Caddy with
caddy-tailscale, not behind `tailscale serve`, and its site sent:

```caddyfile
header_up Tailscale-User-Login {http.auth.user.tailscale_login}
header_up Tailscale-User-Name  {http.auth.user.tailscale_user}
```

caddy-tailscale's README gives `tailscale_user` as "same as `user.id`",
the email-ish user ID, and `tailscale_name` as the display name. So the
header the book was keyed on carried a login. `Store#book` looked for a
group named `sync:alpha@kejadlen.dev`, found none, and every user's book
collapsed to the members of `sync:*` — one card of four, which reads
from macOS Contacts as a sync that stopped working.

The server never noticed. A name that matches no group is an ordinary
empty book, and nothing in the app says whose book it just served.

## One value

Identity is now a single string, the requester's login, and there is no
display name in the model. `ProxyAuth.login` reads it, `Web` holds it as
`@login`, and it does the two jobs the old pair split: it keys
`sync:<login>`, and it fills `CardDAVUsername` in the profile `/setup`
serves.

The module doing the reading is `ProxyAuth` now, not `TailscaleAuth`
(the name `docs/plans/2026-09-12-per-user-books.md` still uses): the
header it reads is a setting, and the proxy writing it is the
deployment's to choose.

A login is the identifier a display name never was. The three
consequences `docs/plans/2026-09-12-per-user-books.md` accepted under
"Whose name" — two users sharing a book, a rename moving a user off
their group, a user typing someone else's name to take their book — are
all gone with it. What it costs is group names: `sync:alpha@example.com`
where `sync:Alpha Chen` read as English. A setting for that name is the
next piece of work, not part of this one.

## Which header

`ProTacts.config.identity_header` names the header, and
`PRO_TACTS_IDENTITY_HEADER` sets it. The default is `Remote-User`, what
a reverse proxy conventionally writes the authenticated user to; the
`docs` site in the same Caddyfile already sends it to another backend.
`rake dev` sets `Tailscale-User-Name`, because a dev session has no
proxy in front of it and is testing what the tailnet deployment does.
That name is a misnomer inherited from the Caddy site: its `header_up`
writes `{http.auth.user.tailscale_user}` there, which is the login, not
the display name the header is named for. The app reads a header, not a
meaning, so the misnomer costs nothing but a reader's double take —
correcting it is a Caddyfile change and a resync, not an app change.

The header is trustworthy for the same reason the pair was. `tailscale
serve` strips `Tailscale-User-Login` from an incoming request before it
writes its own, and Caddy's `header_up` with no `+` prefix sets the
field, overwriting whatever arrived. Neither guarantee survives reaching
the app directly, so it still must not listen anywhere but localhost.

The 401 names the header it read and the setting that chose it
(`Web#unauthorized`). A deployment reading one header while its proxy
writes another is the failure this whole change came out of, and the
header name is the only thing that tells the two apart; the refusal said
"no Tailscale identity" before, which named neither.

An unset header name is not a case the config handles: the default
covers an absent variable, and a variable set to nothing names no header
and 401s every request, which is the loud failure this repo prefers to a
quiet fallback.

## What a deployment has to change

The sync token carries the first 16 hex digits of the SHA-256 of the
login (`Web#book_digest`), so moving from a display name to a login
changes every token. A client presenting an old one gets the 410 and
`DAV:valid-sync-token` that `docs/plans/2026-09-12-per-user-books.md`
specified for a renamed user, and resyncs from scratch. That is the
designed path, and it is what the recorded sessions' fixtures moved for.
