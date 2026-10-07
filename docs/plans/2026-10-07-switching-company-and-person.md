# Switching a card between company and person

2026-10-07. The contact editor has a Company box, Contacts.app's own
checkbox: ticked, the card is a company and its name is the one
Organization field; unticked, a person and the First/Middle/Last pair.
Switching moves the name to where macOS keeps it for that kind, which
reverses one policy of `2026-09-24-company-cards.md`: a company's save
now writes `ORG`.

## What macOS does

Recorded, not remembered: the fixture company card switched in
Contacts.app against `rake dev`, two PUTs in `log/dev.log`.

- **Company to person** (exchange `b5ce7eaebe0e`). `X-ABShowAs` is
  dropped — a person is a card without the line, not one saying
  `PERSON` — `ORG` stays as it was, and `N` and `FN` carry the names.
  Unticking alone sent nothing: Contacts would not save a person
  without a name until one was typed.
- **Person to company** (exchange `ec5ce1d8dd03`, the names cleared by
  hand in the same edit). `X-ABShowAs:COMPANY` comes back, `FN` is
  `ORG`'s name, and `ORG` is unchanged.

So macOS keeps a company's name in `ORG`, with `FN` following it. The
editor kept it in `N`'s family slot and left `ORG` alone, which that
plan already named as drift ("a renamed company can drift from the
`ORG` it arrived with"); the recording shows it as a divergence from
the client, so it goes.

## The save

`CardForm.contact_card` asks `CardForm.company?` which kind the save
writes, and writes the name that kind keeps:

- **A company** (`company_name`): the Organization field into `ORG`'s
  first component, the units after it rejoined byte for byte as
  `n_line` rejoins N's; the same name into `FN`; and
  `X-ABShowAs:COMPANY`. `N` is emptied, `N:;;;;` as macOS wrote it: a
  company has no person's name, and one kept in `N` would be a name no
  screen shows, the editor hiding the pair for a company. A person
  ticked a company leaves their names behind, prefixes and suffixes
  too, and a switch back types them afresh, which Contacts.app asked
  for as well. Each line is rewritten only
  where it says something else, so an untouched save of the card macOS
  wrote keeps every byte. A company whose `FN` disagrees with its
  `ORG` (an imported "Bletchley Park" beside "Bletchley Park Trust")
  is the exception: the field shows `ORG`'s name, and the save brings
  `FN` into line with it, as macOS's own PUT did.
- **A person** (`person_name`): `N` and `FN` as before, and
  `X-ABShowAs` removed. `FN` is rewritten whenever the card was a
  company, since the `FN` it had was the organization's name. `ORG` is
  the person's employer, written from the same Organization field
  (`edited_organization`), whose blank removes it — the whole-property
  rule, department and all, those units having no row of their own. A
  POST without the field leaves `ORG` alone, as one without the
  birthday group leaves the birthday.

`CardForm.nameless?` is the refusal both saves share, kind by kind:
the Organization field for a company, either half of the pair for a
person. "A contact needs a name." stands for both, as macOS's own
refusal to save a nameless person did.

The box submits `1` ticked, and a hidden `0` before it otherwise. A
POST with neither keeps the card's kind, so the walk's and any other
form's save cannot switch one by leaving the field out.

## The form

The rows read First, Middle, Last, Organization, then the Company box.
Organization is one row for both kinds, since both keep it in `ORG`:
required while the box is ticked, being the company's whole name, and
otherwise an optional row like the nickname, wearing the editor's
"removed on save" state over an `ORG` the card carries. That state is
bound to the box, so a company's blank, which cannot save, never
claims a removal. A company shows only that row and the box; the
pair is rendered hidden and disabled (`x-show`, `:disabled`), so it
neither submits nor holds the form back with a `required`, and a
switch back mid-edit finds it as it was. The server's render sets all
of it from the card, so the page is right before Alpine runs. The
field's wire name is `organization`: it was `last` because the save
wrote a company's name into N's family slot, which it no longer does.

The field prefills from `ORG`'s first component. A company card
without `ORG` is the older shape, which kept the name in `N` and `FN`,
so it reads `FN`; a person without one gets an empty row, their own
name being no organization's.

## The details page

`ORG` had no screen ("no screen renders `ORG`", the company-cards
plan), which an editable row cannot leave it with. A person's
organization reads under the name and nickname in the header, where
Contacts.app puts it, in body type rather than the nickname's heading
type because it is not a name of theirs. A company's is not repeated:
it is the name above.

The box is a Gloss Checkbox, not a Switch: Gloss reserves Switch for
settings, and this is a fact about the record. Its caption is a
`label for` beside it rather than one wrapping it, because Gloss sets
a wrapping label in the checkbox's own type, over the editor's
caption type.

It sits on the edit page and not the create dialog, which this does
not reopen: the dialog's reasons stand (`2026-09-24-company-cards.md`,
"Creating"), and the page has none of them — no popover to resize, and
a full form to swap rows in.
