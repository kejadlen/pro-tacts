# Project conventions

A CardDAV server for a family address book, in Ruby on Roda.
Contacts are vCard 3.0 documents in SQLite, served as the bytes that
were stored.

`README.md` covers the protocol, the minimal property set macOS Contacts
needs, and the client quirks behind it. Read it before changing any
response — the shape of those responses is empirical, not arbitrary.

## Commands

```bash
rake                  # Type check, then the tests (the default task)
rake test             # The tests alone
rake steep            # Type check lib against the RBS comments in it
rake fixtures         # Re-record response fixtures from current behavior
rake fixtures:extract # A logged exchange's request as a fixture step
                      # (EXCHANGE=id STEP=test/fixtures/<recording>/NN-name)
rake dev              # Dev server on the fixture book, reloading on
                      # change (needs fd and entr)
```

`rake -T` lists the rest. `rake profile:*` needs `PRO_TACTS_HOSTNAME`
and touches installed system profiles, so leave those to the user.

The backlog lives in `ranger`, not GitHub Issues. `RANGER_DEFAULT_BACKLOG`
is already `pro-tacts` — don't pass `--backlog` or verify it.

## Layout

```
lib/pro_tacts/
├── web.rb          # The Roda app; each first path segment is a
│                   # hash_branch in web/
├── web/dav.rb      # Every DAV route and response body, written
│                   # through dav_xml.rb
├── web/*.rb        # The admin screens, one file per section
├── admin/          # The Phlex views they render; card_form.rb reads
│                   # a form back into a card
├── import/         # An uploaded .vcf: read, matched, and written
├── store.rb        # Sequel over SQLite, and every write
├── contact.rb      # The one model of a contact
├── edited_contact.rb # A submission read against the contact it
│                   # replaces, for Store#put
├── vcard.rb        # A card: its bytes, and the writer's half
└── vcard/parser.rb # The reading half
config.ru           # The deployment, and the composition root
demo.ru             # The fixture book behind StubLogin: the Fly apps
dev.ru              # demo.ru, marked as a dev run, for `rake dev`
db/migrations/      # Run on every store open
sig/                # RBS for what an inline comment cannot say
docs/DESIGN.md      # Who the admin screens are for
docs/apple-contacts.md # What the Apple clients do off-spec
docs/rfcs/          # Vendored spec texts the code cites
docs/plans/         # Dated design records
test/fixtures/      # Seed cards, and real client sessions replayed
```

## Fixtures

`test/fixtures/macos-exchange/` replays the confirmed-working macOS
Contacts session, and `test/fixtures/ios-exchange/` the steps where iOS
differs from it. Within each step directory the two files have opposite
standing:

- `request` files are evidence of what a real client sent. Edit them only
  when a new recorded session supersedes this one.
- `response` files are a snapshot of current behavior. Never hand-edit
  them; change the app, run `rake fixtures`, and read the diff before
  regenerating. One you didn't intend is the suite doing its job.

`test/fixtures/cards/` seeds the test database, which is built in a
tmpdir on every run; edit a `.vcf` to change what the replay serves.
Seeding goes through `Store#put` without `client:`, so a test store has
no `sync:*` group; a test that needs everyone's book makes it.

## Gotchas

### DAV

- Response bodies are built with Nokogiri's builder through `DavXml`,
  whose methods are the only elements the server can send. Inside an
  element's block, `it` is the builder, so name an outer block's
  parameter.
- Adding a property to a response is a real decision, not a freebie. The
  current set was found by removing properties until the client broke.
- Cite RFC sections from the vendored text in `docs/rfcs/`, never from
  memory. `getctag` and `push-transports` are in no RFC at all.
- `supported_http_methods` in `config/puma.rb` *replaces* Puma's list:
  a method not named there gets a 501 before Rack runs, so adding a verb
  is two files.
- Every request needs a `Remote-User` header or it gets a 401. That is
  safe only because a proxy writes the header. `StubLogin` fills it in
  for the fixture book in `demo.ru` and nowhere else: never in
  `config.ru`, and never in front of real data.
- Failed DAV exchanges are written whole to `log/exchange.log` under the
  id Sentry carries as the `exchange` tag. Look there first when a
  client asks for something, and promote one with
  `rake fixtures:extract`.

### Errors

- Don't hide errors. Every request runs under Sentry, so a failure
  allowed to raise is reported; a rescue "to be safe" turns it into a
  silently wrong screen. Rescue only an ordinary case with a real
  fallback, and report anything else you catch with
  `Sentry.capture_exception`.
- A read meant to find one row uses `sole`, which raises on none or
  several, and a caller for whom none is ordinary rescues
  `Sequel::NoMatchingRow` at the method (`Store#contact`). Don't turn
  that into a nil-returning read and a `row &&` at every caller. Where
  the rescue would also wrap a transaction, read with `first` and
  return early instead (`Store#delete_group`).
- Card content never reaches Sentry: `send_default_pii` is off, and the
  URL, headers, exception messages, and `capture_message` text must not
  carry it either.
- Nothing above `vcard/parser.rb` handles a parse error. A line that
  will not read comes back with no property, the card is served from
  its bytes regardless, and unknown properties are kept
  (RFC 6352 section 6.3.2.2).
- The one exception is the arrival reports at the PUT
  (`Web#report_broken_assumptions`, `Web#report_unreadable_lines`):
  there and not on read, so one bad card does not alert once per page
  view.

### Store

- What cannot be rebuilt, and the plan behind each, is listed in
  `Store`'s class comment; everything else is an index
  `rake index:rebuild` makes again. A write that touches a card lands
  its change-log entry in the same transaction, and one that touches a
  group its group-change-log entry, because a sync token or a history
  silently skips whatever the log missed.
- An etag is derived from the card, never stored beside it; `Contact`'s
  constructor is the only way to make one. The etag and diff in
  `changes` are what that write served, stored rather than derived
  because nothing can recompute them once the card moves on.
- Schema changes are new migrations under `db/migrations/`; never edit
  one that has run anywhere. SQLite writes the timestamps, so Ruby never
  sets one.
- Those tables are `STRICT`, so every string column needs `text: true`.
  Strings reach the store as UTF-8: the one binary input is the request
  body, relabelled where `write_card` reads it, and the sqlite3 gem and
  SQLite refuse anything else at the bind or the insert.
- The app is handed its store (`ProTacts::Web.store`, set by `config.ru`
  or a test); there is no global. Requiring the app must stay free of
  side effects, and code reads configuration through `ProTacts.config`,
  not `ENV`.

### Code

- `vcard` names a `VCard` and nothing else; a card's octets are `bytes`
  (`Web#write_card`), and a card that needs saying which one keeps its
  own word (`stored`, `rest`).
- A wrong name is fixed where it starts, in the change at hand,
  migration and all. Check what the new word already means in that
  class before taking it.
- A class built once and only read back is a function: put it as a
  `def self.` on the module whose vocabulary it uses (`CardDiff`,
  `Birthday`, `Admin::Format`). If no name fits, ask whether the thing
  should exist at all.
- A screen or button that only restates another page is deleted, and
  the flow lands on the real thing (docs/DESIGN.md).
- Comments carry the reasoning, never a restatement of the line below
  or the test name. Cite reasoning written elsewhere (a `docs/plans/`
  section, an RFC, the owning method) rather than re-deriving it.
  Plans are dated records: write a new one rather than editing an old
  one.
- String literals are frozen (`RUBYOPT` in `.ramekin/config.kdl`).
- `config.ru` must stay ASCII-only (a test enforces it), and
  `rake steep` needs a UTF-8 locale: under a C locale the em dashes in
  comments are invalid bytes.
- Workflow actions are pinned by commit with a tag comment naming that
  commit, never a branch; zizmor flags a mismatch as a code-scanning
  comment while its job stays green.

### Types

- Types are inline RBS comments, checked by `rake steep`; `sig/` holds
  only what that syntax cannot express, each file saying why
  (docs/plans/2026-08-20-type-checking.md). An instance variable
  declaration must come first in the class body.
- Steep refuses three shapes Ruby accepts: a bare `[]` or `{}` outside a
  typed parameter, a literal meant as a tuple, and a local narrowed
  from nil after it was made. Give the first two their own line with a
  trailing `#:` type, and return on the nil before making the third.
