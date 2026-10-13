# pro-tacts

A CardDAV server for my family.

## Simplifying assumptions

- Small, trusted user group (2-3 people) — no permissions or access controls
- Network access via Tailscale — simple authentication
- Apple devices only (it might happen to work on other CardDAV clients, but
  only accidentally)

## What it does

Each person's phones and Macs sync an address book over CardDAV. Everyone
gets the shared family book, and each person can have contacts of their
own on top of it. The server keeps the whole of each card a device writes,
including what it does not understand, so nothing a client stores is lost
on the way through.

A group holds an address or a note written once and shared by every
member's card. A member editing that line on a device changes it for
everyone.

The same server has a web interface for finding and editing contacts and
groups, setting up a device, and importing a .vcf or a Monica export one
contact at a time. Every pull request gets a preview deployment serving a
sample book.

Who is asking is decided by the Tailscale proxy in front of the app, which
writes the identity into a header, so the app must be reachable only
through that proxy: bind it to localhost. `rake db:dump` commits a plain
snapshot of everything to a git repository in the data directory.

Failures are reported to Sentry without any card content; the full
exchange stays in a local log. Every setting is an environment variable,
documented where `ProTacts::Config` reads it.

## Further reading

- `docs/carddav.md`: the responses macOS and iOS Contacts need, and the
  servers to compare against when a client misbehaves.
- `docs/apple-contacts.md`: what the Apple clients do off-spec.
- `docs/DESIGN.md`: who the web interface is for and the rules it holds.
- `docs/plans/`: dated records of each design decision.
- `AGENTS.md`: how to work in this repository.
