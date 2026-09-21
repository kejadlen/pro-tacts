# Importing a .vcf

2026-09-21. Importing is one upload of one file. `/import` takes a
`.vcf`, says what is in it, asks what to do with the properties no
screen here shows, and lands the cards through the store. Everything
that came before it — `import:macos:plan`, `import:macos:finalize`,
`import:status`, the Swift reader they drove Contacts.app with, and the
plan directories under `data/import` — is gone.

## Why the plan machinery went

Yesterday's change (`2026-09-20-import-by-upload.md`) moved the middle
step of an import into the app and left the two ends on a Mac: a rake
task read Contacts.app through a Swift helper and wrote a plan
directory, the plan's cards were uploaded, and a second task went back
to delete the originals. That kept three things alive for one import:

- **A reader for one application.** `script/macos-contacts.swift` spoke
  to the Contacts framework, and everything downstream was shaped by
  what it chose to hand over. A contact could only carry what the
  reader knew to ask for.
- **A plan on disk.** Directories under `data/import`, a status per
  contact, a format version, and the rules for moving a plan from
  active to done — a ledger whose only reader was the machinery that
  wrote it.
- **A checkout on the Mac.** The repository, the gems and a Ruby, on a
  machine whose part in the import was holding an address book.

A `.vcf` replaces all three. Contacts.app exports one (File, Export,
Export vCard), and so does every other address book worth importing
from. The export is the reading, done by the application that owns the
data, and the file is the whole of what has to travel.

What goes with it is the delete: nothing takes the originals off the
Mac any more. Finalize's check — ask the host, contact by contact,
whether it has the card, then delete what it has — was the safe half of
a two-sided sync, and there is no second side now. Deleting what you
exported is a thing to do in Contacts.app, once you have looked at what
landed.

## What comes in

A card is stored as the card it arrived as. That is this server's whole
posture (`2026-08-24-vcard-storage-and-groups.md`), and every property
this address book reads travels through byte for byte. So there is no
field mapping to approve on the way in, and nothing to confirm about N,
TEL, ADR or PHOTO.

What does not come in is everything else. A book exported from
Contacts.app carries properties no screen here shows —
`X-ABRELATEDNAMES`, `X-SOCIALPROFILE`, `X-ABADR`, `PRODID`, whatever
the source thought worth writing — and a card is meant to be the
contact as this app can show it. A book padded with lines nothing can
display is one whose cards nobody can read; the bytes are the least of
it.

RFC 6352 section 6.3.2.2 is not in tension with that. It binds this
server to keep what a *client* submits and does not understand, and it
does (`vcard.rb`): a property macOS PUTs into a card stays in that card
and comes back out of it untouched. An import is the other direction —
a person choosing what their own book is made of — and there the rule
is the opposite one.

"Known" is the reader's list, not the writer's: the envelope, the
fields a screen shows (`Contact`'s own accessors), and BDAY, which the
store takes into the model. Adding a screen for a property is what
brings it in.

A label Contacts hung beside a line it names (`item3.X-ABLabel`) goes
wherever that line goes — a label naming nothing is worse than either
outcome — while a label on a line that is coming in, `item1.ADR`'s
say, comes in with it.

One property is dropped without being mentioned. `PRODID` names the
program that wrote the file rather than anything about the person, and
every export carries one, so counting it as a loss would put a line in
every file's summary and a mark on every contact's row — a mark every
row wears is a mark that says nothing. What goes quiet is the asking,
not the dropping: the line still does not come in, and the card as
exported still shows it struck, that card being the file's own bytes
and a line shown plain there being a line that claims to arrive.

One thing is kept that nothing will show: a line that would not parse
at all. The parser hands it back without a property name, so there is
nothing to show on a screen and nothing anyone could decide about it;
throwing it away unnamed is worse than letting it ride along in the
card's bytes.

## The walk

Dropping silently would be the wrong trade — the person cannot know
what they lost — and a form of radio buttons over property names was
the wrong remedy: it asks about `X-ABRELATEDNAMES` in the abstract,
and the answer it can give back is a line this app composed. What the
importer actually wants is to look at a contact and fix it.

So the review is a walk, four screens rather than a submission:

1. **Choose the file.**
2. **The contacts it holds**, one row each, marked with how many of
   that contact's lines are not coming in, over a summary of which
   properties the whole file is losing. A book is hundreds of contacts
   and only some of them will have anything worth looking at, so the
   list is what says which rows are worth opening — and a file whose
   every loss is noise says so at the top and can be landed unread.
3. **One contact, two cards.** On the left, the card exactly as the
   file wrote it: content lines in monospace, with every line that is
   not coming in struck in Gloss's danger color and labelled "not
   imported" beside it, a strike on its own being a color. On the
   right, the contact editor, pre-filled with what was read and
   pointed at the import, with this book's groups under its fields as
   boxes to tick. Read the spouse's name off the left card and type it
   into the note on the right, in your own words, and put the contact
   where it belongs while you are looking at it.
4. **Confirm**, under a group for the lot, and the cards land as the
   walk left them.

The right-hand card is `Admin::ContactsEdit` itself, not a copy of it.
A second editor for imports would be a place where the two could
disagree — a field an import writes that an edit cannot undo — so the
editor grew four arguments instead (`action`, `back`, `aside`,
`fields`) and the ordinary edit passes none of them. `fields` is the
groups: they belong to the contact rather than to its card, and inside
the editor's own form they save with everything else. The birthday is
split out of the card and into the model here exactly as `Store#put`
splits it, so the
same row renders over a staged card as over a stored contact, and put
back as a BDAY line on save; a BDAY spelling the model does not read
stays in the card untouched, that method's own rule. The one birthday
that cannot make the trip is one no card can spell — a year on its own,
a month without its day (`2026-08-31-partial-birthdays.md`). A stored
contact holds that in the model and serves a card without it; a staged
contact is only its card, so the save says so and asks for the date
again once the contact has landed, rather than dropping it the moment
it was typed.

## The import waits on the server

An import is a directory under `data/imports`, keyed by a minted id
that every screen of the walk carries in its path. Three slots in it.
`original.vcf` is the uploaded file, written once and never again, and
`landing.vcf` the cards as they will land — pared when the import opens
and rewritten whole each time the editor saves one of them. A card that
has been edited still has to show what it arrived as, which is why
both. `groups.json` is which groups each of those cards is joining,
keyed by the card's place in the file: a vCard says nothing about this
book's groups, and a line invented to hold the answer would land in the
contact.

On disk rather than in the browser: a book with pictures in it is tens
of megabytes, and a form carrying it back and forth is the upload done
once per screen. An id off a link is checked against the shape
`ChangeId.mint` draws before it is made into a path — `../../contacts.db`
is a filename too. The directory goes the moment the cards land, and
anything older than a day is swept on the next upload: long enough to
work down a book over an evening, short enough that a closed window
does not leave that book on disk for a week.

A contact is named by its place in the file, there being no minted id
until it lands. That holds because the editor's save rewrites a card in
place and never adds or removes one.

## Landing

`Import::Land` writes through `Store#put` and `Store#regroup` rather
than through the routes those two sit behind. It is not a second way to
write a card — it is the same two writes a client's PUT and the groups
dialog make:

1. Mint an id, and give the card the UID that spells it. The source's
   own UID names a record in a book this is not, and a contact with two
   spellings of its identity is what `rake contacts:reid` exists to
   undo.
2. `Store#put` with `client: true`, so a card this creates joins
   everyone's book the way a client's create does
   (`2026-09-15-client-creates-join-everyone.md`).
3. `Store#regroup` into whichever groups the walk settled on. Two
   questions, asked in the two places they belong. The review screen
   names one group for the lot, `import-<timestamp>` by default — what
   landed together can be found together, and undone together — and it
   is emptiable, a name this server already has joining that group
   rather than colliding with it. Beside each contact's own card, every
   group this book already has as a box to tick: an import is as often
   "these three are from the school list" as it is a batch that only
   needs finding again, and which people those are is exactly what the
   walk is for. Neither is required, and a card in no group is still in
   everyone's book.

   The per-contact boxes ride in the editor's own form, so one Save
   writes the card and its groups together and there is no second
   button to wonder about. They offer this book's groups and no new
   name: naming a group per contact would be four hundred chances to
   spell "Booles" two ways, and a contact's own page can make one the
   moment it lands. What each contact is joining is read back on its
   row in the list, because the walk is a screen at a time and the list
   is where ten screens' worth of decisions are seen at once.

Importing is not idempotent and cannot be. A `.vcf` carries no id this
server minted, so a second upload of the same file is a second set of
contacts. The review screen is what stands in for the `If-None-Match:
*` the old PUT sent: it says how many contacts are about to land, and
under what group name, before any of them do.
