# Project conventions

A read-only CardDAV server for a family address book, in Ruby on Roda.
Contacts are KDL files on disk, rendered to vCard 3.0 on request.

`README.md` covers the protocol, the minimal property set macOS Contacts
needs, and the client quirks behind it. Read it before changing any
response — the shape of those responses is empirical, not arbitrary.

## Commands

```bash
rake                  # Tests (the default task)
rake fixtures         # Re-record response fixtures from current behavior
rake dev              # Dev server, reloading on change (needs fd and entr)
rake profile:install  # Render and stage carddav.mobileconfig for approval
```

`rake profile:*` needs `PRO_TACTS_HOSTNAME` and touches installed system
profiles, so leave those to the user.

## Task management

The backlog lives in `ranger`, not GitHub Issues. `RANGER_DEFAULT_BACKLOG`
is already `pro-tacts` — don't pass `--backlog` or verify it.

## Layout

```
lib/pro_tacts/
├── web.rb          # The Roda app: every route and response body
├── addressbook.rb  # The collection, its ctag, and its sync token
├── contact.rb      # One KDL file → id, vCard, etag
├── vcard.rb        # KDL → vCard 3.0 rendering
├── config.rb       # Every environment read in the app
├── profile.rb      # carddav.mobileconfig generation
└── debug_logger.rb # Full request/response dumps, off by default
lib/roda/plugins/dav_verbs.rb   # PROPFIND and REPORT routing verbs
docs/rfcs/          # Vendored spec texts the code cites
docs/plans/         # Dated design records
test/fixtures/macos-exchange/   # A real client session, replayed
```

## Fixtures

`test/fixtures/macos-exchange/` replays the one confirmed-working macOS
Contacts session. Within each step directory the two files have opposite
standing:

- `request` files are evidence of what a real client sent. Edit them only
  when a new recorded session supersedes this one.
- `response` files are a snapshot of current behavior. Never hand-edit
  them; change the app, run `rake fixtures`, and review the diff.

A fixture diff you didn't intend is the test suite doing its job. Read it
before regenerating.

## Gotchas

- Response bodies are built with heredocs in `web.rb`. A comment written
  inside one is sent to the client — keep notes about the code in Ruby
  comments outside the heredoc.
- Every request needs a `Tailscale-User-Login` header or it gets a 403, so
  a bare `curl` against `rake dev` is refused until you pass one. The
  security of that rests on the app being reachable only through
  `tailscale serve` — never bind it to anything but localhost.
- Unanswered requests (404s and 5xx) are written to `log/unhandled` in the
  fixture layout. When implementing something a client asked for, look there
  first — and strip the identifying headers before promoting a capture into
  `test/fixtures`.
- `config.ru` must stay ASCII-only; a test enforces it, because boot crashes
  under a C locale otherwise. Watch for em dashes in comments.
- `RUBYOPT=--enable-frozen-string-literal` is set in `.ramekin/config.kdl`.
  String literals are frozen; mutating one raises.
- Application code reads configuration through `ProTacts.config` only; add
  a method to `config.rb` rather than reaching for `ENV`. The Rakefile is
  outside that rule and reads `PRO_TACTS_HOSTNAME` directly.
- `config.ru` is the composition root. Requiring the app must stay free of
  side effects — the test helper depends on that, and `config.ru` never
  runs under test.
- The code cites RFC sections next to each handler. Verify a section
  number against the vendored text in `docs/rfcs/` before writing it; do
  not cite from memory. Two properties macOS needs (`getctag`,
  `push-transports`) are in no RFC at all.
- Adding a property to a response is a real decision, not a freebie. The
  current set was found by removing properties until the client broke.
- `docs/plans/` entries are dated records of what was decided then. Write
  a new one rather than editing an old one to match current behavior.
