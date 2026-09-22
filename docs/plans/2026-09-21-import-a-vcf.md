# Importing a .vcf

2026-09-21. Importing is one upload of one file. `/import` takes a
`.vcf`, says what is in it, asks what to do with the properties no
screen here shows, and writes each card through the store as that
card's own screen is looked over and saved. Everything that came
before it — `import:macos:plan`, `import:macos:finalize`,
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
came in.

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

So the review is a walk, three screens rather than a submission:

1. **Choose the file**, which opens straight into the first contact
   in it. A list built from a file nobody has looked at yet is a stop
   on the way to the same place, and it stands beside every card
   anyway.
2. **What the whole file is losing**, a click back up that list.
3. **One contact, two cards**, side by side. On the left, the card exactly
   as the file wrote it: content lines in monospace, with every line that is
   not coming in struck in Gloss's danger color and labelled "not imported"
   beside it, a strike on its own being a color. On the right, the contact
   editor, pre-filled with what was read and pointed at the import, with
   this book's groups under its fields as a filtered list of boxes to tick,
   the filter doubling as the way to name one it does not have yet. Read the
   spouse's name off the left card and type it into the note on the right,
   in your own words, and put the contact where it belongs while you are
   looking at it. The Save on that screen is the import of that contact: it
   goes into the book there and then, in whatever the boxes beside it say.
   It is the one editor in the app whose Save creates the record rather than
   amending it, so it says where the card is going — "save to the book" —
   and the row beside it wears the unsaved rail until it has been pressed.

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
again once the contact is stored, rather than dropping it the moment
it was typed.

## The list is a sidebar

The contacts are not a screen of their own. They are a column down
the side of both screens after the upload, so opening a row never
costs your place in the list: the row being read is marked, the row
after it is the next thing to click, and what the last ten screens
settled is in view while the eleventh is open. A book is hundreds of
contacts and only some of them will have anything worth looking at,
so the list is what says which rows are worth opening — and that is
a thing to read *while* reading one, not instead of.

It is a `.record` block like the thing beside it, caption row over
card, so the two columns' cards start at the same height. Two columns
beginning a rung apart read as a mistake before they read as anything
else. Its caption is the link back to the screen about the file,
which has no row of its own to be reached from.

Two facts per row, and the walk turns on both.

**Whether the contact is in the book** — a rail in the accent down the
inside edge of every row that is not. Everything is unsaved until its
own screen says otherwise, and a walk broken off overnight and come
back to has to say which rows those are. Words were the first try and
were too much: "not saved" on every row of a list that starts out
entirely unsaved is a column of the same sentence, and it took the one
slot the row's other fact wants. It is the rows still to do that wear
the mark, because what is worth marking is what is left. The word is
still in the row for a screen reader, which cannot see a rail.

**What the card is losing**, as a diff's own mark at the row's
trailing edge — `-3`, in the sign-and-color shape a change-log entry
wears (`.diff-removed` in admin.css). A sentence for it made every
marked row a line of prose to read, and the number is the whole of
what a row has to say about it: how many, and that it is a loss.

The walk is wider than the reading column the rest of the app gets,
because three things stand in it: the list, the card as exported, and
the editor. Those last two are two columns or one and never the
auto-fit in between — squeezed to a third of the ordinary wide page
the fallback was always the stack, and a card read beside its own
source is the whole point of the screen.

## Nothing waits for the end

The first shape of this had a confirm at the end: the walk wrote its
decisions down, and one button at the bottom of the list wrote every
card at once. What that bought was a single point of no return, and
what it cost was everything around it.

- **A walk that has to be finished to be worth anything.** A book is
  hundreds of contacts, and looking them over is an evening rather
  than a sitting. Written only at the end, that evening's work is held
  by a temporary directory and a browser tab, and stopping halfway
  imports nothing at all.
- **A second record of decisions already made.** The groups ticked
  beside a card had to be staged, because nothing could be written
  yet — so a contact's groups lived in two places, and a slot on disk
  existed whose only reader was the button at the bottom.
- **A button that means more than it says.** "Import 242 contacts",
  under a list where twelve rows have been read and two hundred and
  thirty have not, is one press standing for two quite different
  decisions.

So the Save is the import. A contact is in the book the moment its own
screen says so, and the list reads that back: a row that has come in
says so and leads to the contact rather than back into the editor,
which is also the answer to what a second Save on it would mean. The
walk is resumable because nothing is being held back — a tab left
overnight, a window closed, a crash, all read the same way.

That makes the end of the walk a thing to say rather than a thing to
press. Saving the last unsaved row ends it; a "finish" on the list ends
it early. Either way the rows nobody opened are left behind with this
copy of the file, which the importer has their own of, and what came in
is listed on the same page an import has always ended on.

One thing is settled up front, and that is the group for the lot:
every Save files its contact under it. It is named when the import
opens, `import-<timestamp>`, and nothing renames it. A name typed
before anything has been looked at is a name for nothing; a name typed
after the first contact is in would leave that one under the old name
and put the rest somewhere else, which is one import in two groups.
What *is* editable is the membership, which belongs beside each
contact's own card and is a contact at a time.

## The import waits on the server

An import is a directory under `data/imports`, keyed by a minted id
that every screen of the walk carries in its path. Three slots in it.
`original.vcf` is the uploaded file, written once and never again, and
`revised.vcf` the cards as they will come in — pared when the import
opens and rewritten whole each time the editor saves one of them. A card that
has been edited still has to show what it arrived as, which is why
both. `saved.json` is what the import has already done: the group it
files its arrivals under, and the contact each saved card became, keyed
by the card's place in the file. That last map is only how the list
knows which rows are done — the store is the record of the contact
itself — and it is the whole of what this holds back, the groups a
contact joins being written by the same Save that writes the contact.

On disk rather than in the browser: a book with pictures in it is tens
of megabytes, and a form carrying it back and forth is the upload done
once per screen. An id off a link is checked against the shape
`ChangeId.mint` draws before it is made into a path — `../../contacts.db`
is a filename too. The directory goes the moment the walk ends, and
anything older than a day is swept on the next upload: long enough to
work down a book over an evening, short enough that a closed window
does not leave that book on disk for a week.

A contact is named by its place in the file, there being no minted id
until it is written. That holds because the editor's save rewrites a card in
place and never adds or removes one.

## Writing them in

`Import::Write` writes one card, on the Save of that card's own screen,
through `Store#put` and `Store#regroup` rather than through the routes
those two sit behind. It is not a second way to write a card — it is
the same two writes a client's PUT and the groups dialog make:

1. Mint an id, and give the card the UID that spells it. The source's
   own UID names a record in a book this is not, and a contact with two
   spellings of its identity is what `rake contacts:reid` exists to
   undo.
2. `Store#put` with `client: false`, and everyone's book joined below
   with the rest. A client's own create takes `client: true` and joins
   it unconditionally (`2026-09-15-client-creates-join-everyone.md`);
   an import is a person deciding what their book is made of, and that
   is a box on the screen.
3. `Store#regroup` into whichever groups this contact's screen settled
   on — all of them, the group for the import included, `Import::Write`
   knowing that one from no other answer because there is nothing it
   could do about it that it does not do about the rest. The import's
   own group is named when the upload happens, `import-<timestamp>`, so
   what arrived together can be found together and undone together; a
   name this server already has joins that group rather than colliding
   with it. Beside each contact's own card, every
   group this book already has as a box to tick: an import is as often
   "these three are from the school list" as it is a batch that only
   needs finding again, and which people those are is exactly what the
   walk is for. Neither is required, and a card in no group is still in
   everyone's book.

   Both groups a card comes in under stand among those boxes rather
   than out of sight, ticked, because the question this screen answers
   is what the contact will be in and leaving one out is the same
   silence the walk exists to undo. Both can be unticked, for the same
   reason: an arrival that does not belong with the lot is exactly the
   kind of thing the walk is for deciding, and so is a card that is to
   sit on the server without going out to anybody's phone.

   That second one costs `Store#put`'s `client: true`, which every
   other create here passes. The flag answers this very question and
   answers it the one way, so an import passes `client: false` and
   joins everyone's book through `Store#regroup` with the rest — the
   box is there to be unticked, and the answer has to have somewhere
   to be no. Nothing else rides on the flag: it adds that one
   membership and does nothing else.

   The group for the import is a name rather than an id until
   something makes it, which is the first Save to go in under it, so
   it rides as one of the staged names on that first screen and as an
   ordinary box after. Everyone's book is missing from the list on one
   screen in the life of a server — the first card of the first import
   into an empty book, which is the write that creates it — and a row
   for a group that does not exist would be a worse answer than none.
   So it arrives at `Import::Write` as the answer rather than as a
   group, and is resolved there the way a name is.

   The per-contact boxes ride in the editor's own form, so one Save
   writes the card and its groups together and there is no second
   button to wonder about. They are filtered and capped, the groups
   dialog's own filter and cap rather than a second set
   (`Admin::GroupFilter`, which both pickers now render — see
   `2026-09-22-a-few-groups-at-a-time.md`): a book with three hundred
   groups is the same screen as a book with three, and this is the
   screen the walk opens once per contact.

   The filter is also how a group this book does not have yet is
   asked for. Naming no group exactly, it offers itself as one to
   make, and what that rides as until the Save is a name rather than a
   group: a group created while its card is still being looked over is
   one left behind if that card is never saved. A name waiting like
   that shows as a box of its own, ticked and in the italic the groups
   dialog gives a name that is not a group yet, so it can be taken off
   again — and filtered alongside the real groups, so a name this
   contact is already making is not offered a second time as a name to
   make. It is made by the Save, with the contact it was named for,
   and found rather than made again by the next card that asks for it
   (`Import::Write#group_id`, which is also how the group for the lot
   carries across the walk).

   Nothing is staged between screens, which is why a card opened
   afresh has no box ticked: there is no earlier answer to read back,
   the Save that would have written one being the Save that writes the
   contact. A save sent back to be fixed — a blank name, a birthday no
   card can spell — is the one case where there is something to carry,
   and it comes back with its boxes as the form had them.

Importing is not idempotent and cannot be. A `.vcf` carries no id this
server minted, so a second upload of the same file is a second set of
contacts. The walk is what stands in for the `If-None-Match: *` the old
PUT sent: a row is looked at before it comes in, and once it has, both
its row and its screen lead to the contact it became rather than back
into the editor — so the second press of a Save, and the back button
onto a screen already done, are the same nothing.
