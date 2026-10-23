# A row edits its label in the type column

2026-10-22. The editor can change a handle's service and nothing else's
type: a phone, an email, and an address show theirs as a caption no
field reaches. The handle got its field as a second input in the value
column (`2026-10-18-signal-handles.md`, "The service is the row's"),
which made the handle the one row whose type moves out of the type
column on the edit screen while the record card keeps it there
(`Admin::ContactCard`), and the one row with its own layout
(`.handle-row`, and the phone-width stacking rule after it). Doing
that again for emails and addresses would give three shapes for one
idea.

So every repeatable row — phone, email, handle, address — edits its
label in the same place it shows it: the type column, as a text field
with the kind's usual words offered beside it. The value column holds
the value and nothing else. Each kind of row writes its own label, so
the form and the save walk all four the same way. No card already in
the store is rewritten.

## One word, three spellings

What the type column says is one word to a reader, and the card spells
it three ways:

| Spelling | Where | Example |
|---|---|---|
| `TYPE` parameters | phone, email, address | `TEL;type=CELL;type=pref` |
| An `X-ABLabel` sharing the line's group | phone, email, address | `item1.TEL` + `item1.X-ABLabel:Google Voice` |
| `X-SERVICE-TYPE` | handle | `IMPP;X-SERVICE-TYPE=signal:x-apple:alice.42` |

That word is the row's **label**: Contacts' own name for it, and the
name `Contact::Phone#label` already holds for the second spelling
alone. It widens to whichever spelling the line carries — the
`X-ABLabel` where the line has one, unwrapped (`VCard.unwrap`, so
Apple's `_$!<Other>!$_` reads `Other`), the `TYPE` values the reader
shows otherwise, joined as `Format.type_label` joins them today, and
nil for neither. A handle's label is its service. `Format.type_label`
then becomes `row.label || kind`, and the record card and the editor
read the one method.

Emails and addresses read the `X-ABLabel` for the first time. The
phone labels plan left them out because the only email label in the
data was Apple's `Other`, which said less than "email"
(`2026-09-18-phone-labels.md`, "What the data has"). An editor changes
that: a field prefilled blank over a line labeled `Other` is a field
hiding what the save would overwrite, so the 31 emails labeled `Other`
start reading `OTHER`.

## The row writes its own label

The difference between the kinds is where the label is written, and
that belongs to the row, not to a `case` in the save. Each row class
in `Contact` — `Phone`, `Email`, `Address`, `Handle` — answers the same
three things:

- `#label`, above.
- `#fields`, the row's values by form field name: `{"value" => ...}`
  for a phone, an email, and a handle, the six components for an
  address (`Contact::ADDRESS_COMPONENTS`).
- `#edit(card, label, fields)`, the card with the row's own lines
  rewritten — removed, for a blank value. A class method `.add` of the
  same shape writes an added row. The row takes the card rather than
  handing back lines because a labeled row is two lines, and only the
  row knows which; a label can also need a free property group from
  the rest of the card.

Phone, email, and address share their label rule through functions on
`Contact` (`edited_row`, `added_row`, `removed_row`), each naming its
own vocabulary; the handle keeps `Contact.handle_line` as its rule. The address's value
splice (`CardForm.address_line`) moves onto `Address` with it. This is
the precedent `Contact.handle_line` already set: the line's spelling
lives with the model that reads it.

### The typed kinds' rule

A label that submits what the row read leaves the header alone, byte
for byte — the phones' rule for a value, applied to the word beside it.
A changed label:

1. Takes off what the reader showed: the `TYPE` values that made up the
   old label, and the `X-ABLabel` line, if any. It keeps what the
   reader hid — `pref`, `voice` on a `TEL`, `internet` on an `EMAIL` —
   and every other parameter. The write removes exactly what the read
   showed, so a relabel cannot drop anything the field never rendered.
2. Writes the new word as `TYPE` values where every comma-separated
   word in it is one Contacts models for that property, and as an
   `X-ABLabel` otherwise. The line keeps its group if it has one, and
   takes the lowest free `itemN` if it does not — a new
   `VCard#free_group`, the read the phone labels plan said the editor
   would need (`2026-09-18-phone-labels.md`, "The plan card carries
   one"). The label line goes immediately after its row.
3. Writes neither for a blank label.

The vocabulary starts as what a client has been seen writing:
`home` and `work` on all three, `cell` on a phone
(`docs/apple-contacts.md`, "The client rewrites every card it
touches", and the fixtures), with `TYPE` values written uppercase as
Contacts writes them. `Other` is written wrapped, `_$!<Other>!$_`,
because that is how 31 emails in the macOS data carry it. Anything else
— `school`, `main`, `Google Voice` — is a custom label. That is the
safe direction to be wrong in: a `TYPE` Contacts cannot model is moved
into an `X-ABLabel` on its next touch anyway (`docs/apple-contacts.md`,
"An address type the client cannot model becomes a custom label"),
while an `X-ABLabel` the client could have modeled as a type still
shows as the word that was typed. A word joins the vocabulary when a
recorded session shows Contacts spelling it as a type.

The group form survives Contacts' round trip, renumbered but bound
(`docs/apple-contacts.md`, "An annotation survives only on its own
line", second table), so a label written this way is one the client
keeps.

### Removing a row removes its label

A blank value removes the row's lines, and for a labeled row that is
two lines. Today's save substitutes only the `TEL`, so blanking a
Google Voice number leaves its `X-ABLabel` naming nothing — the hazard
the phone labels plan flagged as "easy to get wrong" ("What this
leaves"). Rows carry their label's parsed line beside their own
(`label_line`), and the walk below removes both. This fixes that
orphan on the way.

## The form

Every repeatable row posts the same shape, a hash of fields under its
digest, and every added row the same shape under its add index:

```
phone[<digest>][label]     phone[<digest>][value]
email[<digest>][label]     email[<digest>][value]
handle[<digest>][label]    handle[<digest>][value]
address[<digest>][label]   address[<digest>][street] ...
new_<kind>[<i>][label]     new_<kind>[<i>][<field>]
```

That retires the bare `new_phone[]` and `new_email[]` arms, and the
handle's `service` field becomes `label`. `Web#card_form_params` becomes
one loop over the kinds, each kind's field names from its row class,
and `CardForm.edited_values`, `.edited_handles`, and `.edited_addresses`
become one walk: for each row, skip it where label and fields both
submit what it read, and hand it the card (`#edit`) otherwise; then
add each added row. The three walks differ today only in
what this plan moves onto the rows.

### The type column's field

The caption `span` becomes a text `input` naming the label, with a
`datalist` of the kind's vocabulary: a free word, the suggestions a
tap away. That is the platform's own combobox — Gloss defines none —
and it carries the custom label without a "Custom…" option and a
second step. Its placeholder is the kind (`phone`), so an unlabeled
row still reads `PHONE` in the column, as today, and the field takes
the column's mono uppercase so a row reads the same before and after
the edit (docs/DESIGN.md, "Alignment is the layout"). A handle's list
offers `signal`, the one service this server writes; any other service
is typed.

The row becomes a `div` rather than a wrapping `label`, as the address
row already is, because it holds two controls and a label names one;
each input carries an `aria-label` (`phone label`, `phone`).

The removal state stays on the value. Blanking the label is a relabel
to nothing, not a removal, so admin.css's `data-blank-removes`
selectors ask after the value column's inputs only, and the strike
moves from the caption onto the label field's text.

The added rows' `<template>`s become one per kind, rendered by a loop
over the kinds rather than an `x-if` written for each.

## What goes

- The handle row's second field, `HANDLE_FIELDS`, `.handle-row`, and
  its phone-width stacking rule: the service is back in the column the
  record card shows it in.
- `CardForm.edited_handles` and `.edited_addresses` as separate walks,
  and `edited_values`' bare-array insert.
- `Format.type_label`'s three arguments.

## What this leaves

- The group editor (`Admin::GroupsEdit`) keeps its address caption. A
  group's lines are bare by CHECK (`db/migrations/004_groups.rb`), so
  a group's address can carry a `TYPE` but never an `X-ABLabel`, and
  the custom half of the field has nowhere to write. Offering the
  vocabulary alone there is a select, a different control, and waits
  for someone to want it.
- A handle's own `TYPE` (`home`, `work`), which Contacts can write
  beside `X-SERVICE-TYPE`, is kept and not shown, as today.
- The vocabulary is inferred, not recorded. The first session that
  relabels a phone to `main` or `iPhone` in Contacts settles those
  spellings.
- Identical duplicate lines still share a digest (`ContactsEdit#value_row`).

## Order

One PR, in commits that each pass:

1. `VCard#free_group`, and the rows carry `label_line`; blanking a
   labeled phone removes its label. The orphan fix stands alone.
2. `#label` widens and emails and addresses read theirs; the record
   card shows them.
3. The rows answer `#fields` and `#edit`, the form takes its one
   shape and `CardForm` its one walk, and the type column's field
   replaces the handle row's second field. One commit: the form's new
   shape and the field that posts it cannot pass apart.

The hegel properties in `test/pro_tacts/admin/test_card_form.rb` grow
two ways: a relabel reads back as the label typed, with no label left
naming nothing, and the untouched save posts every kind's label too.
