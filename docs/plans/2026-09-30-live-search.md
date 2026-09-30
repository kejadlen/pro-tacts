# Live search

The header's search was a GET form: type, submit, and the dashboard
reloaded as a results page for `/?q=`. It now narrows as it is typed:
in a dialog the header's button opens over any screen, and on a phone
on a search page of its own. The dashboard's results page is gone.
Task pnrqpyvk.

## What was weighed

The task named three ways to make it live:

- **Filter in the page with Alpine**, over every contact embedded in
  it. No server work, but it ships the whole book to the browser and
  writes the match a second time in JavaScript — and since
  `Admin::Search` (task ynwtzotq) the match is words across fields,
  phones by their digits, and a ranking, not one substring check.
- **Pagefind**, which indexes at build time. Contacts change at
  runtime behind the identity gate, so the index would be rebuilt on
  every card write and served behind the same check, and its ranking
  would replace ours rather than keep it.
- **Keep matching on the server** and have the input fetch results.
  One implementation of what a match is, at a request per pause in
  typing against local SQLite.

The server won, for the reason the first two lose: `Admin::Search`
stays the one place a match is decided. SQLite FTS5 and typo
tolerance were set aside for a family-sized book in the same pass.

## Why a dialog

The first cut kept the input in the header and swapped the
dashboard's contacts column for the fetched results. That made the
search live on one screen only; everywhere else, typing still had to
be submitted and land on the dashboard. A dialog works the same over
any screen, and makes the header's control a button: one height on
every screen, and none of the fold-and-open machinery the header
input needed on a phone.

`/` opens it from anywhere a key is not already typing into a field.
That is what replaced "focused and ready" in `docs/DESIGN.md`: a
button cannot hold focus for a page, and opening the dialog on load
would cover the dashboard someone came to see.

## Why a phone gets a page

A phone's screen is already about the dialog's width, so there the
dialog was only a smaller screen laid over the screen. A phone's
header links to `GET /search` instead, a page of its own holding the
same field. It keeps its address on the
query as it is typed, so going back to it from a result lands on
the results, and in a GET form back to itself it answers a
submitted query without script, which the dialog cannot. The header
renders both the dialog's button and the page's link, and CSS shows
one per width. Before a word is typed the page lists the recently
updated contacts, the dashboard's own rows, rather than standing
empty; the dialog opens over a screen with its own content and
stays empty until typed into.

## Why the results page went

With the dialog, `/?q=` would restate what the dialog already shows,
and a screen that only restates another is deleted (`docs/DESIGN.md`).
The search page is not that page back: it is the phone's way to the
search, not the dashboard answering a query. The results are
uncapped and scroll, since there is no "see all" to send a long list
to.

## Shape

- `GET /search/results?q=` answers `Admin::SearchResults`, a fragment
  rather than a page: the matched contacts, then the matched groups,
  or the recently updated contacts for a blank query.
- `Admin::SearchField` is the input and that list. It waits for
  typing to pause, cancels a fetch the next one supersedes, and moves
  a highlight through the result links with the arrow keys, which
  Enter follows.
- `Admin::SearchDialog` holds the field over any screen, wider than
  a phone; `GET /search` (`Admin::SearchPage`) holds it on a phone,
  with the results of its own `?q=` rendered in.
- The dashboard is recency and birthdays, and nothing else.
