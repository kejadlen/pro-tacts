# Book names

2026-09-16. A login's book can go by a name other than the login, so the
group choosing it reads `sync:Alpha Chen` rather than
`sync:alpha@example.com`. This is the setting
`2026-09-15-identity-from-one-header.md` left for next, under "One value".

## Where the name lives

In the database, in `book_names` (db/migrations/009_book_names.rb), one
row per login that has a name. A login without a row goes by itself.
There is no screen for it: `rake book:name LOGIN=... NAME=...` sets one,
and the same task with no `NAME` goes back to the login. Naming a book is
done once per user per deployment, and an environment variable holding a
map of logins would be a second place a group name is spelled.

Names are unique, since two logins sharing a name would share a book,
and `*` is refused as everyone's.

## The group moves with the name

`Store#name_book` renames the login's `sync:` group, if it has one, in
the same transaction as the row, through `Store#rename_group`. The book
keeps its cards, and every member is logged as moved, so a client syncing
it refetches rather than missing anything.

Renaming the group from the groups screen does not update the row. The
book then names a group that is not there, the same as a login whose
group was renamed before this.

## Matched as spelled

`Store#book` used to match `sync:<login>` in any case, because the name
was a display name a user could recase at will. With a name that is the
deployment's to choose, a login whose case reads badly gets a name
instead, so the group name and the login are both compared as exact
bytes, the comparison the unique index on group names already makes
(`2026-09-15-group-names-are-unique.md`).
