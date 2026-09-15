# Client creates join everyone's book

2026-09-15. This changes one rule in
`2026-09-12-per-user-books.md`, "The wire": a PUT that creates a card
adds it to `sync:*`, not to the writer's `sync:<name>` group.

The card still stays in the writer's book, because `sync:*` is in every
book. It also reaches everyone else's, and that is the intent. A new
contact is in plain sight for the family, and one that should be a
single person's is taken out of `sync:*` in the admin UI, where
membership is visible and editable. The writer's own group was neither:
a phone never shows it, and nobody was told a group had been made.

The create no longer needs the writer's name, so it no longer depends
on how a `sync:<name>` group is spelled. Books still match the display
name in any case (`Store#book`), but no write has to find the one group
that a name means.
