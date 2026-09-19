# Book names in the dump

2026-09-19. `rake db:dump` writes `book_names.yml` beside the cards,
the birthdays, and the groups: every login that has a book name, and
the name it goes by.

## Why it belongs there

The dump holds what the store cannot rebuild
(`2026-09-12-database-dump.md`), and a book name is exactly that. Nothing
re-derives a `book_names` row — the migration says so in as many words
(db/migrations/009_book_names.rb) — and it is not carried by any card, so
it went out of a dump the way the birthdays would have.

Losing one is not a cosmetic loss either. A login whose name is gone
goes back to syncing `sync:<login>`, and the `sync:<name>` group the dump
does hold is then a group nobody's book points at
(`2026-09-16-book-names.md`, "The group moves with the name"). The row
is what ties a login to its group, and it was the part not written
down.

## What it looks like

| Path | Holds |
|---|---|
| `book_names.yml` | The name each login's book goes by, keyed by login |

One file rather than a directory, the birthdays' shape: a row is a login
and a string, and there is one per user of the deployment. Written every
dump, `--- {}` for a deployment that has named no book, so the file is
the answer rather than its absence being one.

Logins are ordered in `Store#all_book_names` rather than by the task, the
birthdays' arrangement reversed. `Store#birthdays_by_id` is shared with
the listing reads, which do not care, so `tasks/db.rake` sorts what it
writes; nothing but the dump reads all the book names, so the order the
file needs lives with the read.

## Still not read back

Nothing reads a dump back, this no more than the rest. A restore would
need an importer, and `Store#name_book` is the writer it would call —
which renames the `sync:` group as it goes, so an importer replaying
`book_names.yml` after the groups would rename what it had just restored.
The order is the importer's problem to solve when one is written.
