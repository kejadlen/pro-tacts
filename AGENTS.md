# Project conventions

A CardDAV server for a family address book, in Ruby on Roda.
Contacts are vCard 3.0 documents in SQLite, served as the bytes that
were stored.

`README.md` covers the protocol, the minimal property set macOS Contacts
needs, and the client quirks behind it. Read it before changing any
response — the shape of those responses is empirical, not arbitrary.

## Commands

```bash
rake                  # Tests (the default task)
rake steep            # Type check lib against the RBS comments in it
rake fixtures         # Re-record response fixtures from current behavior
rake index:rebuild    # Derive the parsed index again from the stored cards
rake dev              # Dev server, seeded from test/fixtures/cards into a
                      # throwaway tmpdir on every start, reloading on change
                      # (needs fd and entr)
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
├── store.rb        # Sequel over SQLite: cards, change log, derived index
├── contact.rb      # id and vCard, with the etag derived from the card
├── vcard.rb        # vCard 3.0 escaping and folding, and what a card is
├── vcard/parser.rb # One card's bytes into properties
├── config.rb       # Every environment read in the app
├── profile.rb      # carddav.mobileconfig generation
└── debug_logger.rb # Full request/response dumps, off by default
lib/roda/plugins/dav_verbs.rb     # PROPFIND and REPORT routing verbs
lib/sequel/extensions/sole.rb     # `first`, minus the ambiguity
db/migrations/      # Sequel migrations, run on every store open
sig/                # RBS for what an inline comment cannot say
docs/rfcs/          # Vendored spec texts the code cites
docs/plans/         # Dated design records
test/fixtures/cards/            # Seed cards for the test database
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

`test/fixtures/cards/` holds the vCards the test database is seeded from.
The database itself is built in a throwaway tmpdir on every run and is
not a fixture; edit a `.vcf` to change what the replay serves.

## Gotchas

- Response bodies are built with heredocs in `web.rb`. A comment written
  inside one is sent to the client — keep notes about the code in Ruby
  comments outside the heredoc.
- Every request needs a `Tailscale-User-Login` header or it gets a 403, so
  a bare `curl` against `rake dev` is refused until you pass one. The
  security of that rests on the app being reachable only through
  `tailscale serve` — never bind it to anything but localhost.
- Unanswered requests (404s, app-level 403s, and 5xx) are written to
  `log/unhandled` in the fixture layout. When implementing something a
  client asked for, look there first — and strip the identifying headers
  before promoting a capture into `test/fixtures`.
- Anything added to a request body must be assumed to reach Sentry. Card
  content is redacted by `ProTacts::SentryScrubber`; a new kind of sensitive
  field would need its own rule there.
- `config.ru` must stay ASCII-only; a test enforces it, because boot crashes
  under a C locale otherwise. Watch for em dashes in comments.
- `RUBYOPT=--enable-frozen-string-literal` is set in `.ramekin/config.kdl`.
  String literals are frozen; mutating one raises.
- `supported_http_methods` in `config/puma.rb` *replaces* Puma's default
  method list rather than extending it. Any method the app answers must be
  named there or Puma returns 501 from the HTTP parser, before Rack runs —
  so the request never reaches the app and `UnhandledRequests` cannot
  capture it. Adding a route is two files, not one.
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
- `cards` and `changes` carry timestamps; the index tables deliberately
  do not, because their rows are thrown away and rebuilt. SQLite writes
  the stamps, so nothing in Ruby should set one.
- Schema changes are Sequel migrations under `db/migrations/`, applied
  by `Store#migrate` on every open — there is no separate migrate task
  to forget, and no way to serve from a database a deploy left behind.
  Never edit a migration that has run anywhere; add the next one.
- Those tables are `STRICT`, so every string column needs `text: true`:
  Sequel's plain `String` is a varchar, which STRICT refuses. Strings
  reach the store as UTF-8 by contract, and the adapter enforces it: the
  sqlite3 gem encodes every bound value to UTF-8, so binary-flagged
  bytes above 7 bits raise at the bind, while bytes that are not UTF-8
  at all are refused by SQLite on the insert. The one binary input is
  the request body — Rack requires input in ASCII-8BIT and
  Rack::RewindableInput enforces it — relabelled to UTF-8 where it is
  read, in `write_card`. Path-derived ids need no relabel: Puma hands
  PATH_INFO over still percent-encoded (set verbatim from
  REQUEST_PATH), so an id off the wire is ASCII.
- The app is handed its store rather than reaching for one:
  `config.ru` builds it and sets `ProTacts::Web.store`, and a test does
  the same with a throwaway. There is no global `ProTacts.store`, so
  nothing in a request depends on load order or on a lazy memo several
  threads could race into. `Store.connect` is for a database that is not
  the one being served — a fixture, a test, a task pointed elsewhere.
- `test/test_helper.rb` sets `ENV` before it requires the app, and the
  requires cannot all move to the top because of it: the app reads
  configuration as it loads, since the unhandled-request middleware is
  given its directory at class-definition time. Set it afterwards and
  the 404 captures land in `log/` instead of `tmp/`.
- Only three things in the database cannot be rebuilt: the cards, the
  change log, and the birthdays — a partial date has no vCard 3.0
  spelling, so it lives beside its card rather than in it (see
  docs/plans/2026-08-31-partial-birthdays.md). Everything else is a
  projection of the cards that `rake index:rebuild` will make again,
  so no repair is ever needed for it. A write that touches a card must
  land its change-log entry in the same transaction, because a client's
  sync token silently skips whatever the log missed.
- A read whose filter is meant to identify one row uses `sole`, not
  `first` — `first` answers with one of several rather than saying the
  filter was too loose. `sole` raises either way it is wrong:
  `Sequel::NoMatchingRow` for none, `Sequel::Sole::TooManyRows` for
  more. A caller for whom no row is ordinary rescues the first, which is
  what `Store#contact` does for the 404 path. The store loads the
  extension on every open.
- An etag is derived from the card, never stored beside it: `Contact`
  hashes what it serves, and `Contact.for` is the only way to make one.
  The etag in `changes` is the exception and is not the same fact — it
  is what the card hashed to at that write, which nothing can recompute
  once the card moves on.
- `vcard.rb` no longer raises on what it does not recognize, and must
  not start again. It used to render a hand-edited format, where an
  unknown key meant a typo silently losing data; it now reads stored
  cards, where an unknown property means a client using the spec, and
  RFC 6352 section 6.3.2.2 requires keeping it. A card that will not
  parse is still served, it just does not get indexed.
- `escape` and `fold` in `vcard.rb` have no caller yet. They are the
  writer's half of the module, kept deliberately for PUT and the web
  editor, and tested directly rather than through anything that serves.
- `docs/plans/` entries are dated records of what was decided then. Write
  a new one rather than editing an old one to match current behavior.
- Types live in the code, as RBS comments: `#:` above a method for its
  type, `# @rbs` for instance variables and skips, `#:` at the end of a
  line for a constant or an assertion. `rake steep` checks them, and
  `sig/` holds only what that syntax cannot express — the gems, which
  ship no signatures, and the classes the inline parser refuses. Each
  file there says which limit put it there; see
  docs/plans/2026-08-20-type-checking.md.
- An instance variable declaration has to be the first thing in the
  class body. Further down it is reported as an unused annotation.
- `rake steep` needs a UTF-8 locale, which comes from the environment
  rather than anything in this repo. RBS reads source in the default
  external encoding, so under a C locale the em dashes in these comments
  are invalid bytes and the parse dies on them. The same footgun the
  ASCII-only rule in `config.ru` exists for.
