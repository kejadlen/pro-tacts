# Pro-tacts — Design Notes

Pro-tacts is a single-user admin for a personal contact store: the place where
one person curates the contacts and groups that get synced out to their own
devices. It is a tool, not a product. Nobody is being onboarded, nothing is
being sold, and there is no second user to design around.

This document describes the system the interface is built on — the rules that
should hold as screens get added or reworked. It deliberately says nothing
about file layout or the current screen inventory, both of which will change.

## Foundation

Built on the **Arbitrary Definitions** design system: its tokens, its
components, its voice. Nothing here overrides that system — this document only
records the decisions Pro-tacts makes *within* it.

- Type, space, and radius come from the Utopia scale tokens (`--step-*`,
  `--space-*`, `--radius-*`). No hardcoded px for type or rhythm.
- One accent, used sparingly: active nav, links, focus. Never two.
- Semantic red and green mean destructive and confirmed. They are not
  decoration and never carry emphasis.
- Flat surfaces, hairline borders, at most one floated element per view
  (the dialog). No gradients, no blur, no shadow stacking.
- Motion is a 120–160ms background or color transition on hover and focus.
  Nothing enters, nothing bounces, nothing animates on press.

## The core idea: search first, no browsing

Contacts and groups are both **found**, not browsed. A list of everything is
not useful past a hundred records and becomes actively hostile past a
thousand, so no screen exists to scroll the whole set.

Every collection screen is the same shape:

1. A search input at the top, focused and ready.
2. Results while there's a query.
3. **Recently updated** when there isn't — the ten or so records touched last,
   sorted by update time.

Recency is the answer to "what was I doing?", which is the actual question
someone opening this app has. Match generously: a contact should be findable
by name, by any of its values, and by the groups it belongs to.

## Records are cards, not forms

A contact or group opens as a full card, not a row in a split pane and not a
modal. The card *is* the record — reading it and editing it are the same view.
There is no view mode, no edit mode, and no Save button. A value is clicked,
changed, and committed.

Consequences worth keeping:

- **Empty attributes do not render.** A record with one phone number shows one
  row, not a scaffold of blank fields. The card's height is the record's real
  weight — an unfilled record should look unfilled.
- **Adding is explicit.** A quiet add affordance opens a dialog that names the
  attribute types available. Multi-part additions (picking a group, then a
  role) are steps inside that one dialog, never a chain of popovers.
- **Removal is inline and reversible-feeling.** A small, low-contrast control
  on the row itself; destructive color only on hover.

## Alignment is the layout

Detail cards use one three-column grid — **icon · type · value** — shared by
every row in the card and by both contacts and groups. Every row aligns to
those columns, including rows that have no type label (a birthday, a note):
they span or occupy the value column rather than inventing their own layout.

This is the single most load-bearing rule in the interface. Two records side by
side, or the same record before and after an edit, should read as the same
object. Any new attribute type earns a row in the existing grid; it does not
earn a new section shape.

Density is uniform: value text at one step below body, type labels in mono
uppercase at two steps below. Multi-line values (an address) break inside the
value column and stay in it.

## Relationships are navigable

A contact shows its groups; a group shows its contacts. Both render as chips,
and **every chip is a link** — clicking it opens that record's card. A remove
control inside a chip stops there and does not navigate.

Relationships are symmetric in the data and should feel symmetric in the UI:
whatever a contact can say about a group, a group can say about the contact,
and adding from either side is the same dialog.

Groups are first-class records, not tags. They have their own attributes and
their own notes, and their card uses the same grid as a contact's.

## Voice

Plain, present tense, no encouragement.

- Labels are catalog tags: `MOBILE`, `WORK`, `HOME`. Mono, uppercase, short.
- Empty states state the fact: "No contacts match." Not "Try another search!"
- Confirmations describe what happened, once, in a toast, and leave.
- No exclamation points. No emoji. No addressing the user as a customer.

## When adding something new

Ask, in order:

1. Can search find it? If a new record type isn't findable by typing, it isn't
   done.
2. Does it fit the existing grid? A new attribute is a row. If it seems to need
   its own layout, the layout is probably wrong.
3. Does it render nothing when empty?
4. Is it reachable from both sides of any relationship it participates in?
5. Is there a Save button? There shouldn't be.
