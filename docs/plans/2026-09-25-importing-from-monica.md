# Importing from Monica

2026-09-25. `/import` takes Monica 4's account export (Settings,
Export, "Export to JSON") as well as a `.vcf`. The export is read as
the `.vcf` it composes, a card per contact, and from the upload on it
is the walk as it was (`2026-09-21-import-a-vcf.md`): the composed
file is the import's original, pared by `Vcf.read`, and read beside
the editor a contact at a time, matched and folded as any card is
(`2026-09-23-merging-on-import.md`).

Three smaller changes ride with it, because a Monica card, by file or
by export, needs them: `ORG` and `X-ABShowAs` come in, `SOURCE` and
`REV` are dropped without remark, and a card's `CATEGORIES` are ticked
beside it as groups.

## Why the JSON and not Monica's vCards

Monica writes a vCard for one contact at a time; a whole book comes
out of its CardDAV server, through a client, as a `.vcf` the walk
already takes. What it does not carry is most of what Monica is for.
Its exporters (`app/Services/VCard/ExportVCard.php` on the 4.x
branch) write names, phones, emails, addresses, the birthday, a
photo, the company, the job, social profiles and tags. Notes,
relationships, pets, how you met, reminders and everything that
happened are nowhere in the card.

Monica 4's JSON export is the one place those come out whole. It is
Monica's own beta (`version: 1.0-preview.1`), and Monica 5 has no
equivalent, so this reads Monica 4 and nothing else; a book on Monica
5 comes in by its CardDAV `.vcf` and loses what a card cannot carry.

## A card, not a second walk

The export could have had screens of its own. It gets none, because
everything the walk does is already the right thing to do with a
Monica contact: show what it was, open the editor on what is coming
in, offer the contact it looks like, file it under its groups. So
`Import::Monica.vcf` composes cards at the upload and the route hands
them to `Vcf.cards` as if the file had been a `.vcf` all along.

A composed card carries everything Monica knows, not only what this
book reads. That keeps the walk's promise that nothing is lost without
having been shown first: the left-hand card is the whole record, and
what is not coming in is struck on it like any other line.

## Where each part goes

The shapes are Monica's export resources (`app/ExportResources`): a
record's columns, a `properties` object, and a `data` array of
collections `{count, type, values}`. Relationships, photos and
activities are the account's, and name contacts by uuid.

- **Into a field.** First, middle and last names; the nickname; the
  company as `ORG`; each contact field whose type Monica filed as a
  phone or an email; each address, labelled with the name Monica gave
  it the way Contacts labels a row; the avatar Monica stored, from the
  account's photos, where it is a data URL rather than a Gravatar.
- **The birthday**, where a card can spell it: a whole date, or a
  month and day where Monica was told the year is unknown. One Monica
  worked out from an age holds a year it guessed and a day it made
  up; no card spells that truthfully, and a staged card could not
  hold a year alone anyway, so it stays behind as a line of its own
  to read and enter on the contact's page once it is in.
- **Into the one `NOTE`** (`2026-09-25-one-note-per-contact.md`), a
  paragraph each: the description and every note, those being words
  someone wrote; then the relationships (`Spouse: Sam Booles`, in
  Monica's English names for its types), the pets, the food
  preferences, and how you met. These are prose about the person, and
  the note is the one place a contact holds prose.
- **Into groups.** Tags are `CATEGORIES` on the card, and the walk
  ticks a group of each name beside it (below).
- **Left behind, in view.** The job as `TITLE`, social profiles,
  reminders, tasks, calls, conversations, life events, gifts, debts,
  activities and a death date, each an `X-MONICA-` line (or the vCard
  property that already says it) struck on the card as exported. They
  are things to do or things that happened rather than things about
  the person, and the one worth keeping is a copy into the note away.

A contact Monica only knows by name — `is_partial`, a relative added
from someone else's page — is not a card of its own. It is a name in
the relationships of the contacts it is related to.

## Tags are groups

Monica files people by tag; this book files them by group, and the
two mean the same thing. So a card's `CATEGORIES`, from a Monica
export or any `.vcf` that carries them, are ticked beside it: the
book's own group where one has that name, and otherwise a name the
Save makes, the way a name typed into the filter is
(`Import::Write#group_id`). They are ticks rather than writes, so the
walk's rule stands: nothing joins a group the importer did not look
at, and any of them can be unticked.

A tag spelling a sync group ticks nothing. Which phones a card goes
out to is the one box beside a card a tag should not be able to tick.

The `CATEGORIES` line itself is struck on the card as exported, being
no line this book keeps, but is not counted as a loss: what it said
arrives, as the ticked boxes beside it.

## Small changes to what a card brings in

- **`ORG` and `X-ABShowAs` are known.** A company card's editor reads
  its name out of `ORG`, and the flag is how the book knows to show it
  as one (`2026-09-24-company-cards.md`, which named this as the bulk
  path). A fold fills `ORG` where the contact has none, as it does a
  nickname.
- **`SOURCE` and `REV` are noise**, beside `PRODID`. Monica writes
  both on every card: where the card came from and when it last
  changed there. Counted, they would mark every row of a Monica file
  with a loss nobody is going to copy into a card.

## Non-goals

- **Monica 5, and Monica's API.** Monica 5's CardDAV `.vcf` imports
  as any `.vcf` does. Its CardDAV server serves groups as cards
  (`KIND:group`); a file that carries them is not read as groups yet,
  and they arrive as rows of their own.
- **A second import of the same export.** As with a `.vcf`, an export
  carries no id this server minted; the match beside each card is
  what stands between a second upload and a second set of contacts.
