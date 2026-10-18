# Search keys

2026-10-17. Every request the live search makes used to build the
whole book. It now reads a short folded key for each card, matches
those keys, and builds only the contacts it found.

## What was slow

Before, each request to `GET /search/results?q=` built every contact
from the index (`Store#listed_by_id`). It then parsed each one and
folded its values for `Admin::Search`. That cost grew with the size of
the book and hardly depended on the query. The book was the 600-card
seed from `2026-10-14-lists-read-the-index.md`, scaled to 1,000 cards,
with requests sent in process:

| Query | Before | After |
|---|---|---|
| `zzz` (no hits) | 510 ms | 18 ms |
| `ada` (66 hits) | 380 ms | 48 ms |
| `ad` (134 hits) | 420 ms | 67 ms |
| `a` (every card) | 457 ms | 364 ms |
| blank (10 recent) | 168 ms | 17 ms |

The browser was never the cause, because the results always came from
the server (`2026-09-30-live-search.md`). A query that matches every
card still builds and renders every card. That is what an uncapped
list costs, and a cap would be a separate decision.

## Shape

- `search_keys` holds one row per card, an `Admin::Search::Key` as
  JSON: the folded text fields, each number's digits, and the words of
  the name and nickname, for ranking. `Store#reindex` writes the row
  next to the card's other index rows, and `#rebuild_index` derives it
  again. Migration 014 fills it for the cards that are already stored.
  The migration uses the app's own `Search.key`, unlike 012, which
  spells its rule out so it cannot drift. This table is index, not
  data, so what it has to agree with is the search that reads it today.
- `Admin::Search` is still the one place that decides a match. It
  builds the key (`Search.key`) and reads it. The matching rules have
  not changed.
- A group's contribution is keyed at search time from its label and
  from what it lends (`Group#reading`). It is never copied into its
  members' keys, because then a rename or a change to a lent line
  would have to rewrite every member's row. A group lends no name, so
  a match on a group's label never ranks as a name hit.
- A blank query and the dashboard read the 10 newest rows. They no
  longer build the whole book in order to show 10 contacts.

## Why not FTS5

The trigram tokenizer handles substrings and, in the bundled SQLite
3.53, folds diacritics, so "zoe" finds Zoë. It cannot match a word
shorter than three characters, though, and every search starts with
those keystrokes. Phones would still need their own digit column. The
ranking would stay in Ruby, and group labels would have to be copied
into every member's row. At family size, walking the stored keys
already takes milliseconds. If the book ever grows enough that the
walk becomes slow, these same columns can feed an FTS5 table.
