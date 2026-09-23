# The members screen

2026-09-23. The group's card grows its "edit members" link a working
one: `/groups/:id/members`, a box per contact in the book, ticked for
the ones in the group, filtered and capped the way the groups pickers
are. The link had stood without an href since the show screen was
written, waiting for this.

## Why a screen and not the dialog

The contact's side of the same relationship is a popover
(`Admin::GroupDialog`). A contact's groups are a handful; a group's
members are the whole book. The popover caps its list at eight rows
because a popover cannot scroll past its own footer
(docs/plans/2026-09-22-a-few-groups-at-a-time.md); a page scrolls, and
the cap there is for the reading rather than the clipping — which is
the import's situation too. And the show screen already renders the
members list under the card; the screen is that list made editable,
which is where its link has always said it would be.

## The save is a diff, not a set

The dialog's own posture (`was[]`, `Web#apply_groups`): the form sends
what it toggled beside what the page loaded with, and the save moves
only the difference. A membership moved elsewhere since the page
loaded is in neither list, so the save says nothing about it — no
version guard, nothing to revert, no snapshot to refuse. The editor's
guard protects a wholesale replace (a name, the lines); membership
toggles touch only what was toggled, so there is no overlap to lose.

`Store#edit_members` wraps the moves in one transaction, leavers first
and joiners last (`#edit_group`'s reason), over `add_member` and
`remove_member` themselves — so a `sync:` group still moves cards
between books exactly as the editor moves them, and the change log
still records every card whose served bytes moved.

## The filter is the groups' own

`Admin::GroupFilter` takes a third consumer. Its nouns are
parameterized — the placeholder, the empty line, the show-all count —
and the members screen passes "contacts"; the filter, the cap, the
never-capped ticked row, and the show-all button are unchanged, for
the plan's own reason: a second answer to that problem would only be
a place where the two could disagree.

The offer to make what the filter names is not rendered. A filter
word cannot mint a contact — that is the dashboard's dialog, with its
name fields — so the placeholder says nothing about adding, and
`Empty` drops its `!creatable` clause along with the offer: the clause
exists to hold the message back while the make-it row stands in for
it, and on a list where nothing can be made it would hide "No
contacts match" behind a name no row will ever carry.

The list is the show screen's own — `ul.card` rows, avatar and name
at the list typography and spacing, the checkbox standing where a
row's link does — because the screen is that list made editable, and
a settings-checkbox stack wearing list parts reads as neither. The
rows being `li`s rather than the labels the dialog and the import
tick is why `GroupFilter`'s state reads its rows off `data-label`
(the attribute every row already carried) instead of the element:
the cap must hide the whole row, border and padding included, not
the box alone inside an li that stays standing. Rows are matched on
`Format.name_label`, nickname and all, because that is the name a
person filters by, and sort the way every contact list sorts
(`Format.sort_key`).

The form owns the picker's Alpine state and so wraps both cards, the
record's own above and the list under it — which puts the filter
inside the form it filters, Enter in it guarded rather than
submitted, the import's own answer where there is no outside to
stand in.
