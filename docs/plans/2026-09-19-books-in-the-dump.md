# Books in the dump

2026-09-19. `rake db:dump` writes `books.yml` beside the cards, the
birthdays, and the groups: every login whose book goes by a name, and
the name it goes by.

Written as `book_names.yml` on the day, off the table's name then;
`2026-09-21-books-not-book-names.md` renamed both.

## Why it belongs there

The dump holds what the store cannot rebuild
(`2026-09-12-database-dump.md`), and a book's name is exactly that.
Nothing re-derives one of those rows — the migration says so in as many
words (db/migrations/009_book_names.rb) — and no card carries it, so it
went out of a dump the way the birthdays would have.

Losing one is not a cosmetic loss either. A login whose name is gone
goes back to syncing `sync:<login>`, and the `sync:<name>` group the dump
does hold is then a group nobody's book points at
(`2026-09-16-book-names.md`, "The group moves with the name"). The row
is what ties a login to its group, and it was the part not written
down.

## What it looks like

| Path | Holds |
|---|---|
| `books.yml` | The name each named book goes by, keyed by login |

One file rather than a directory, the birthdays' shape: a row is a login
and a string, and there is one per user of the deployment. Written every
dump, `--- {}` for a deployment that has named no book, so the file is
the answer rather than its absence being one.

Logins are ordered in `Store#all_books` rather than by the task, the
birthdays' arrangement reversed. `Store#birthdays_by_id` is shared with
the listing reads, which do not care, so `tasks/db.rake` sorts what it
writes; nothing but the dump reads all the books, so the order the file
needs lives with the read.

## Still not read back

Nothing reads a dump back, this no more than the rest. A restore would
need an importer, and `Store#name_book` is the writer it would call —
which renames the `sync:` group as it goes, so an importer replaying
`books.yml` after the groups would rename what it had just restored.
The order is the importer's problem to solve when one is written.
