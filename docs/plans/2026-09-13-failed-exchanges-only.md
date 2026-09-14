# Only failed DAV exchanges are logged

2026-09-13. Amends "Every DAV exchange is logged locally" in
`docs/plans/2026-09-13-dav-observability.md` before it shipped: the
exchange log keeps the DAV exchanges that went wrong, not every one.

An exchange went wrong when its status is 400 or more other than 401,
when it raised, or when it reported to Sentry while it ran. The last
case covers an arrival report on a PUT that succeeded, and it keeps the
id honest: every `exchange` tag Sentry carries names an exchange the log
holds. A 401 stays out because it is the identity gate refusing a
request that names nobody, whose body came from outside the tailnet.

The DAV routes are the paths under `/dav/` and `/.well-known/`, plus any
verb the admin screens do not answer, wherever it lands. That catches
the PROPFIND on `/`, and a DAV request to a path nothing routes.

A successful write still has to be readable, for the probes in
`tasks/probe.rake` and for a photo fixture. `PRO_TACTS_DEBUG`, which
switched the old debug log on, now widens the exchange log to every DAV
exchange, and the footer's `+debug` label stays with it.

The rest of that section stands: one middleware, a size-rotated file
under `log/`, the id on the request's Sentry scope, and a rake task to
extract an exchange as a fixture.
