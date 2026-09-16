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
rake fixtures:extract # A logged exchange's request as a fixture step
                      # (EXCHANGE=id STEP=test/fixtures/<recording>/NN-name)
rake index:rebuild    # Derive the parsed index again from the stored cards
rake book:name        # Name a login's book and rename its sync group
                      # (LOGIN=login NAME=name; no NAME clears it)
rake db:dump          # Write the cards, birthdays, and groups to data/dump
                      # (DUMP=path to move it)
rake dev              # Dev server, seeded from test/fixtures/cards into a
                      # throwaway tmpdir on every start, reloading on change
                      # (needs fd and entr)
rake profile:install  # Download carddav.mobileconfig from the app and
                      # stage it for approval
```

`rake profile:*` needs `PRO_TACTS_HOSTNAME` and touches installed system
profiles, so leave those to the user.

## Task management

The backlog lives in `ranger`, not GitHub Issues. `RANGER_DEFAULT_BACKLOG`
is already `pro-tacts` — don't pass `--backlog` or verify it.

## Layout

```
lib/pro_tacts/
├── web.rb          # The Roda app: the identity gate and the root;
│                   # each first segment is a hash_branch in web/
├── web/dav.rb      # Discovery and the address book: every DAV route
│                   # and response body
├── dav_xml.rb      # The elements those bodies are written with, one
│                   # object per namespace
├── web/contacts.rb # The card browser and its editor
├── web/groups.rb   # The group screens and their editor
├── web/setup.rb    # The device setup screen and its profile
├── store.rb        # Sequel over SQLite: cards, change log, derived index
├── contact.rb      # the one model of a contact: id, vCard, etag,
│                   # and the structured accessors over the card
├── vcard.rb        # vCard 3.0 escaping and folding, and what a card is
├── vcard/parser.rb # One card's bytes into lines
├── config.rb       # Every environment read in the app
├── profile.rb      # carddav.mobileconfig generation
├── exchange_log.rb # Failed DAV exchanges, whole, under an id Sentry
│                   # carries
└── refusal_alerts.rb # DAV refusals as Sentry warnings, one per route
lib/roda/plugins/dav_verbs.rb     # PROPFIND and REPORT routing verbs
lib/sequel/extensions/sole.rb     # `first`, minus the ambiguity
db/migrations/      # Sequel migrations, run on every store open
sig/                # RBS for what an inline comment cannot say
docs/rfcs/          # Vendored spec texts the code cites
docs/plans/         # Dated design records
test/fixtures/cards/            # Seed cards for the test database
test/fixtures/macos-exchange/   # A real client session, replayed
test/fixtures/ios-exchange/     # Where a second client differs from it
```

## Fixtures

`test/fixtures/macos-exchange/` replays the confirmed-working macOS
Contacts session, and `test/fixtures/ios-exchange/` the steps where iOS
sends something macOS does not — a namespace prefix spelled differently,
a header it omits, a verb macOS never sends. Within each step directory
the two files have opposite standing:

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

- Response bodies in `web/dav.rb` are built with Nokogiri's builder through
  `DavXml`, whose methods are the only elements the server can send. Inside
  an element's block, `it` is the builder, not an enclosing block's value,
  so name the outer block's parameter.
- Every request needs a `Remote-User` header or it gets a 401. `rake dev`
  fills it with `alpha@example.com` when a request has none (`dev.ru`),
  so pass it only to ask as someone else. The security of
  that rests on the app being reachable only through a proxy that writes
  the header itself — never bind it to anything but localhost.
- DAV exchanges that went wrong (a status of 400 or more but 401, a
  crash, or a report to Sentry) are written whole to `log/exchange.log`,
  each line prefixed by the id Sentry carries as the `exchange` tag.
  When implementing something a client asked for, look there first, and
  promote an exchange into `test/fixtures` with `rake fixtures:extract`,
  which strips the identifying headers.
- No request body reaches Sentry: `send_default_pii` is off in
  `config.ru`, because card content never leaves the machine. The URL,
  headers, exception messages, and `capture_message` text still do, so
  keep card content out of all four.
- Don't hide errors. A `rescue` that swallows an exception and returns a
  fallback value reads as defensive but is actually the opposite: it turns
  a bug or corrupt data into a silently wrong screen instead of a loud one.
  Every request already runs under `Sentry::Rack::CaptureExceptions`, so an
  unexpected failure that's allowed to raise is reported and visible —
  rescuing it locally "to be safe" makes it neither. Rescue only what's an
  ordinary, anticipated case with a real fallback to show (e.g. no row for
  a requested id — see `Store#contact`'s 404 path), never "this might
  fail, better catch it." A rescue that catches must still send it to
  Sentry — `Sentry.capture_exception` at the minimum.
- `config.ru` must stay ASCII-only; a test enforces it, because boot crashes
  under a C locale otherwise. Watch for em dashes in comments.
- `RUBYOPT=--enable-frozen-string-literal` is set in `.ramekin/config.kdl`.
  String literals are frozen; mutating one raises.
- `supported_http_methods` in `config/puma.rb` *replaces* Puma's default
  method list rather than extending it. Any method the app answers must be
  named there or Puma returns 501 from the HTTP parser, before Rack runs —
  so the request never reaches the app and `ExchangeLog` cannot log it. Adding a route is two files, not one.
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
  configuration as it loads, since the exchange log is given its path at
  class-definition time. Set it afterwards and the failed exchanges land
  in `log/` instead of a tmpdir.
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
  hashes what it serves, and its constructor is the only way to make
  one — no second path takes an etag on trust. The etag in `changes` is
  the exception and is not the same fact — it is what the card hashed
  to at that write, which nothing can recompute once the card moves on.
  Its `diff` is the same kind of fact and the same kind of exception
  (`CardDiff`): the lines that write added and removed, of the card as
  served, so the etag and the diff describe one download. It records a
  card's lines and not its bytes — folding is normalized away — so it
  says what a write did without being able to rebuild what it did it
  to.
- Nothing above `vcard/parser.rb` handles a parse error, and nothing
  should start. `Parser.lines` is the only read: a line that will not
  read comes back as a Line with no property. The card is served from
  its bytes regardless, `VCard` and `Contact` answer from the lines
  that read, and the index holds what this server understood. There is
  no repair to make, which is why no caller is asked to look for one.
- The one exception is the arrival reports at the PUT, and it is not
  handling: a broken assumption is news that something this server was
  built on is wrong and reports as an error, and an unreadable line is
  ordinary bad input and warns (`Web#report_broken_assumptions`,
  `Web#report_unreadable_lines`). They live at the PUT because that is
  the arrival — a read happens on every page load, and one bad card
  must not alert once per page view.
- `vcard.rb` no longer raises on what it does not recognize, and must
  not start again. It used to render a hand-edited format, where an
  unknown key meant a typo silently losing data; it now reads stored
  cards, where an unknown property means a client using the spec, and
  RFC 6352 section 6.3.2.2 requires keeping it.
- `escape` and `header_of` in `vcard.rb` are the writer's half of the
  module, and the web editor's saves are rebuilt through them
  (`admin/card_form.rb`). There is no `fold` beside them: a served card
  is stored bytes going out untouched, and the editor writes the one
  line it changed, so nothing has ever had a logical line to fold.
  `Parser.unfold` is the reading half and does have callers.
- `vcard` names a `VCard` and nothing else, and a card with no
  qualifier to give it is named `vcard`. A `vcard` holding a card's
  bytes is the confusion the rule exists to stop: the two sit one
  `VCard.new` apart, and at a PUT that gap is the whole question —
  the body arrives as octets and everything below the route wants
  the card — so the octets are `bytes` (`Web#write_card`). A card
  that needs saying which one keeps its own word (`stored`, `own`,
  `rest`). The `cards` column and the `text/vcard` media type spell
  it the same way and are neither of them variables.
- `docs/plans/` entries are dated records of what was decided then. Write
  a new one rather than editing an old one to match current behavior.
- Comments carry the reasoning; the code carries the rest. One that
  restates the line below it has nothing to say, and neither does a
  test comment that restates its test name — the names in `test/` are
  sentences already. Where the reasoning is already written down, cite
  it rather than re-derive it: a `docs/plans/` entry and the section
  within it, an RFC section, or the method that owns the rule. Two
  copies of an argument drift apart, and the plan holds the whole of
  it.
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
