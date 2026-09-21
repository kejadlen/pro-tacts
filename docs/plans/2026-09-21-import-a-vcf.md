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

## Two screens, because of the question

A card is stored as the card it arrived as. That is this server's whole
posture (`2026-08-24-vcard-storage-and-groups.md`): RFC 6352 section
6.3.2.2 requires a server to keep what it does not understand, and this
one keeps it byte for byte. So there is no field mapping to approve on
the way in, and nothing to confirm about N, TEL, ADR or PHOTO.

There is one real question. A book exported from Contacts.app carries
properties no screen here shows — `X-ABRELATEDNAMES`, `X-SOCIALPROFILE`,
`X-ABADR`, `PRODID`, whatever the source thought worth writing. Kept,
they travel with the card and come back out of it untouched; they are
simply invisible in this app. That is the right default and it is not
always what is wanted: some of it is the source's bookkeeping, and some
of it is worth reading even with no field to read it in.

So the importer gets three choices per unknown property:

- **keep it in the card** — the default, and the one that loses nothing.
- **drop it** — for what the source keeps and this book has no use for.
- **write it under the note** — for a value worth reading anyway. A
  spouse's name is worth more under the note than nowhere.

The question cannot be asked until the file has been read, which is why
this is two requests rather than one. The first stages the upload and
surveys it; the second spends the answers. Each unknown property is
shown with how many lines wear it and a few real values out of that very
file, so the choice is made looking at the book's own data rather than
at a property name.

The decision is per property name, not per line: `X-SOCIALPROFILE;
type=twitter` is not a second decision from `X-SOCIALPROFILE`. A label
Contacts hung beside a line it names (`item3.X-ABLabel`) goes wherever
that line goes — a label naming nothing is worse than either choice.
Under the note, the label is what the value is called, so the note
reads `Spouse: Jane` and not `X-ABRELATEDNAMES: Jane`.

"Known" is the reader's list, not the writer's: the envelope, the fields
a screen shows (`Contact`'s own accessors), and BDAY, which the store
takes into the model. Adding a screen for a property is what takes it
off the list of things to decide about.

## The file waits on the server

Between the two requests the bytes sit under `data/imports`, keyed by a
minted id, and the review screen carries the id in a hidden field. Not
the file: a book with pictures in it is tens of megabytes, and a form
that carries it back to the server is the upload done twice. An id off a
form is checked against the shape `ChangeId.mint` draws before it is
made into a path — `../../contacts.db` is a filename too. The file goes
the moment its cards land, and anything older than an hour is swept on
the next upload.

Rack's 128-part multipart limit is no longer raised in `config.ru`. A
plan was one part per card; a `.vcf` is one part.

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
3. `Store#regroup` into the import's group, made if it is missing. The
   group is named `import-<timestamp>` by default and can be renamed or
   emptied on the review screen: what landed together can be found
   together, and undone together.

Importing is not idempotent and cannot be. A `.vcf` carries no id this
server minted, so a second upload of the same file is a second set of
contacts. The review screen is what stands in for the `If-None-Match:
*` the old PUT sent: it says how many contacts are about to land, and
under what group name, before any of them do.
