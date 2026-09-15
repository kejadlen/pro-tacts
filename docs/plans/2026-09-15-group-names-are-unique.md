# Group names are unique

2026-09-15. This changes one rule in
`2026-09-12-per-user-books.md`, "Selection rides on groups": every
group's name is its own, not the `sync:` names alone.

The groups dialog on a contact's card creates a group by the name typed
into its filter, so a name is something a person writes rather than
something they pick. Two groups called Booles put two identical tags on
a card, and neither the tag nor the save that made the second one says
which group is which. The refusal is the database's
(`db/migrations/008_group_names.rb`), so it holds for the group
editor's rename and the create route as well as for the dialog.

Exact bytes rather than a case fold. SQLite's NOCASE folds ASCII alone,
so a folded index would refuse "booles" beside "Booles" and admit "ZOË"
beside "Zoë". The dialog offers to create only a name that no group's
lowercased label already spells, so a case variant takes a hand-made
POST.

Nameless groups are unaffected: a unique index admits any number of
NULLs, and a group with no name is displayed by its id.
