# Pro-tacts — Design Notes

Pro-tacts is a single-user admin for a personal contact store: the place where
one person curates the contacts and groups that get synced out to their own
devices. It is a tool, not a product. Nobody is being onboarded, nothing is
being sold, and there is no second user to design around.

This document describes the system the interface is built on — the rules that
should hold as screens get added or reworked. It deliberately says nothing
about file layout or the current screen inventory, both of which will change.

## Foundation: Gloss

Pro-tacts is a project under **Arbitrary Definitions**, so it inherits
[**Gloss**](https://github.com/kejadlen/gloss) — that umbrella's design
system. Gloss is the visual spine; this document only records the decisions
Pro-tacts makes *within* it. When the two disagree, Gloss wins.

What that inheritance actually means:

- Three stylesheets, in order: `tokens.css`, `base.css`, `components.css`. No
  build step. IBM Plex Mono is the one webfont. Pro-tacts vendors its own copy
  under `public/vendor/gloss` (see `rake gloss:vendor`) rather than depending
  on Gloss at runtime.
- **Every value is a `var(--gl-*)`.** No hex, no duration, no px for type or
  rhythm anywhere in Pro-tacts' own CSS. Type is `--gl-step-*`, space is
  `--gl-space-*`, corners are `--gl-radius-sm|md|lg` (4/6/10px — nothing
  pill-shaped but true pills).
- **Read aliases, never ramps** — `--gl-color-text-secondary`, not
  `--gl-neutral-600`. This is what lets dark mode be a block of repointed
  aliases instead of a second stylesheet.
- **No class API to memorize.** Bare elements (`button`, `input`, `select`,
  native `dialog`), ARIA roles as style hooks (`[role="status"]`,
  `[role="tablist"]`, `[role="switch"]`), `data-*` for variants
  (`data-variant`, `data-size`, `data-tone`, `data-elevated`), and exactly
  seven plain classes. Pro-tacts adds no eighth and no `--`/`__` modifier.
  Before writing a component's markup, read its contract in Gloss'
  `_components/<name>.md` rather than guessing from a sibling.
- **One accent, held constant.** Pro-tacts sets `--gl-color-accent` once and
  never shows two accents in a view. `-ink` and `-soft` re-derive themselves.
- `--gl-color-success` and `--gl-color-danger` are **fixed** — they mean
  confirmed and destructive, never decoration, never emphasis.
- Surface contrast does the elevation work: a bounded surface reads by
  being a step lighter than what surrounds it, never by an outline.
  Hairlines are dividers inside a surface (a CardRow, a table rule), never
  a boundary around one. At most one `--gl-shadow-float` on screen — in
  this app that's the dialog or a toast.
- Motion is `--gl-dur-fast` on hover and focus, named properties only, never
  `all`. Press is not animated. Nothing enters, nothing bounces.
- Icons are Lucide at 16–20px, stroke in `currentColor`, never filled. Nothing
  under `lib/pro_tacts/admin` vendors an icon set yet — until one lands, a
  screen leads a row with its mono type label instead of an icon rather than
  inventing a substitute.
- No gradients, no blur, no translucency, no photography, no brand mark —
  "Pro-tacts" is rendered in type wherever a mark would go.

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
- **Adding is explicit.** A quiet add affordance opens a native `dialog` that
  names the attribute types available. Multi-part additions (picking a group,
  then a role) are steps inside that one dialog, never a chain of popovers —
  and the dialog is the view's one floated layer.
- **Removal is inline and reversible-feeling.** A small, low-contrast control
  on the row itself; `--gl-color-danger` only on hover.

## Alignment is the layout

Detail cards use one three-column grid — **icon · type · value** — shared by
every row in the card and by both contacts and groups. Every row aligns to
those columns, including rows that have no type label (a birthday, a note):
they span or occupy the value column rather than inventing their own layout.

This is the single most load-bearing rule in the interface. Two records side by
side, or the same record before and after an edit, should read as the same
object. Any new attribute type earns a row in the existing grid; it does not
earn a new section shape.

Density is uniform: value text at `--gl-step--1`, type labels in
`--gl-font-mono` uppercase at `--gl-step--2`. Multi-line values (an address)
break inside the value column and stay in it.

## Relationships are navigable

A contact shows its groups; a group shows its contacts. Both render as tags,
and **every tag is a link** — clicking it opens that record's card. A remove
control inside a tag stops there and does not navigate.

Relationships are symmetric in the data and should feel symmetric in the UI:
whatever a contact can say about a group, a group can say about the contact,
and adding from either side is the same dialog.

Groups are first-class records, not labels. They have their own attributes and
their own notes, and their card uses the same grid as a contact's.

## Voice

Gloss' voice, applied here: plain, present tense, no encouragement.

- Type labels are catalog tags: `MOBILE`, `WORK`, `HOME`. Mono, uppercase,
  short.
- Empty states state the fact: "No contacts match." Not "Try another search!"
- Confirmations describe what happened, once, in a `[role="status"]` toast,
  and leave.
- No exclamation points. No emoji. No addressing the user as a customer.

## When adding something new

Ask, in order:

1. Can search find it? If a new record type isn't findable by typing, it isn't
   done.
2. Does it fit the existing grid? A new attribute is a row. If it seems to need
   its own layout, the layout is probably wrong.
3. Does it render nothing when empty?
4. Is it reachable from both sides of any relationship it participates in?
5. Does Gloss already define the component? Use it as documented rather than
   restyling something adjacent.
6. Does it pass Gloss' refusals checklist, the consolidated list of
   generated-interface tells the system refuses to produce?
7. Is there a literal hex, duration, or new class in the diff? There shouldn't
   be. Is there a Save button? There shouldn't be.
