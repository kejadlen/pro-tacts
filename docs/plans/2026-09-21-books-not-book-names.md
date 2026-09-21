# Books, not book names

2026-09-21. The `book_names` table is `books`
(db/migrations/010_books.rb), and the word `book` inside `Store` now
names one thing.

## The table was named for its column

A book is what a login syncs. `book_names` named the table after the
`name` column instead, so the table and the thing it held went by
different words, and every reader had to hold both. A row here is a book
that goes by a name of its own; a login with no row has a book all the
same, which is the state the table exists to record a departure from.

The rename is a rename and nothing else. SQLite carries a table's own
constraints over with it, so 009's two rules — a login holds one row, a
name is one login's — still hold, and no row moves.

## What the word costs elsewhere

`books` cannot mean a table of names while `book` means a set of cards.
`Store#book(login)` answered with the card ids one client syncs, so it
is `Store#book_cards(login)` now, for the same reason `vcard` names a
`VCard` and a card's octets are `bytes` (AGENTS.md). `Web#book` keeps
its name: it is the requester's book, and no table is in scope there.

The pairs that stay, because each already said which half it meant:

| Reads | Answers |
|---|---|
| `Store#books` | The table |
| `Store#all_books` | Every named book, by login — `groups`/`all_groups`'s arrangement |
| `Store#book_name(login)` | The name it goes by, which is the login until one is set |
| `Store#name_book(login, name)` | Sets it, and renames the `sync:` group with it |
| `Store#book_cards(login)` | The card ids that client syncs |

`Snapshot#books` and the dump's `books.yml` follow the table
(`2026-09-19-books-in-the-dump.md`).

## A book has a name whether or not it has a row

`book_name` answered with nil for a login with no row, and all three of
its callers wrote `book_name(login) || login` — the fallback spelled out
again each time, and a name the method's own comment had already said was
the login's. A login with no row has a book all the same, and it goes by
the login, so that is what the method answers now and the `|| login`
goes.

Nothing asked the other question. Whether a book was ever named is not a
thing any screen, task or route branches on: the two writers
(`rake book:name` and the setup POST) set a name or clear one, and both
report what the book goes by afterwards either way. A reader that needs
the distinction can ask the table, but none does, and a nil that every
caller had to undo was not that reader.

## Why now

The feature is five days old (`2026-09-16-book-names.md`) and the dump
was about to write the name into a file that version control would keep.
A rename costs a migration and a pass over one class today; it costs a
dump migration once a deployment's history carries the old file.
