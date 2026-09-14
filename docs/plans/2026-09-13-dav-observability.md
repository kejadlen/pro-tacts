# DAV observability

2026-09-13. Monitoring is rebuilt around one split: Sentry says that a
DAV exchange went wrong, and a local log says what the exchange was.
Card content never reaches Sentry. The admin UI is out of scope and
keeps exception reporting only.

This replaces the scaffolding from early development: `DebugLogger`,
`UnhandledRequests`, the Sentry message in the `not_found` handler, and
`SentryScrubber`.

## Why the scaffolding goes

The 412 is the one status that means a client and the server disagreed
about a card, and neither capture kept it. The debug log held 23 of
them, but it was off by default. `log/unhandled` kept only 404s, mostly
browser icons and probes. Both captures wrapped every route, so admin
traffic made up most of what they recorded.

## Sentry carries no card content

`send_default_pii` is off. sentry-ruby 6.7 then leaves out the request
body, the query string, cookies, and IP addresses
(`RequestInterface#initialize` in `lib/sentry/interfaces/request.rb`).
Card content only ever arrives in a body, so `SentryScrubber` has
nothing left to redact and goes.

Headers are still sent, all but `Authorization`. The tailnet identity
headers leaking would be acceptable, but dropping `Tailscale-User-Login`
and `Tailscale-User-Name` in `before_send` is a few lines, so it does.

The exchange log's logger stays in `exclude_loggers`, for the reason
`DebugLogger` is there today: Sentry's logger hook would turn every
line of it into a breadcrumb, card content included.

## Every DAV exchange is logged locally

One middleware covers the DAV routes: `/dav/`, `/.well-known/`, and
the PROPFIND on `/`. It is always on. It writes each full request and
response to a size-rotated file under `log/`, photo bytes included,
because a fixture of a photo PUT has to come from somewhere.

Each exchange gets an id. The id prefixes the exchange's lines in the
log and is set as a tag on the request's Sentry scope, so an alert
names the exchange to read.

A rake task writes one exchange, by id, in the fixture layout with the
identifying headers stripped. It replaces copying a capture directory.

## Refusals alert

A DAV response of 403, 404, 410, or 412 sends a warning to Sentry. The
fingerprint is the method, the route with the card id replaced, and
the status, so Sentry groups repeats rather than one per card. A crash
already reaches Sentry through `Sentry::Rack::CaptureExceptions`. The
arrival reports at the PUT and the store's BDAY reports are unchanged.

## Not covered

A method missing from `supported_http_methods` in `config/puma.rb` is
refused with a 501 by Puma's parser before Rack runs, so nothing here
sees it.
