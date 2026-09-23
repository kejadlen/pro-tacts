# Merging on import

2026-09-23. A row of the import walk whose card looks like someone the
book already has offers, at the top of its editor, to update that
contact instead of adding a new one. Choosing it re-renders the editor
over the contact with the card folded in, and that screen's Save is
the contact's own edit. Nothing else about the walk
(`2026-09-21-import-a-vcf.md`) changes.

## Why

An import into a book that is not empty meets people it already has.
The walk as it stood could only add them, so the second copy of
someone was the importer's to notice, to reconcile by hand on the
contact's own page, and to delete — after the walk, off a list of
what came in. The row being read is the moment the importer is
looking at exactly this person, so that is where the question goes.

## Finding them

`Import::Match` scores every contact in the book against the arriving
card over the three things a person is recognised by:

- **The name**, by Levenshtein distance over its words sorted, without
  case or punctuation. "Booles, Jane" and "Jane Booles" are one name
  written two ways, and an edit distance over the spellings would call
  them strangers.
- **Each email address**, by Levenshtein distance over the part before
  its @, without case. The domain is shared by everyone at it: over
  whole addresses, "ada@example.com" is four edits in sixteen from
  "mary@example.com", which offered the fixture book's Ada for a card
  that was Mary's. The same handle at two providers is still one
  person.
- **Each phone number**, by Levenshtein distance over its last ten
  digits. A country code or a trunk prefix on one side and not the
  other is still one number, and a digit mistyped is one edit in ten.
  The fixture book's numbers were consecutive — a household at 900101,
  900102 and 900103 — which offered every Boole for every other, so
  they are spread out now rather than the distance given up; a real
  book's numbers are not a sequence.

Each is scored as the share of the longer string an edit leaves alone.
A contact is offered when the best
of any one field clears the threshold — not a sum or a mean. The cases
worth catching are one field agreeing and the others absent or
different: the same email under a nickname, the same number under a
married name. A sum would bury exactly those. The offers are then
ranked by the sum, so of two contacts sharing an address the one that
shares the name too comes first.

The threshold is 0.8, which lets through one edit in five characters —
"Jon Smith" against "John Smith" is 0.9 — and at most three are
offered, best first. Both are guesses about a family's book, and an
offer that turns out wrong costs one look and nothing else: nothing
is written until the importer chooses it and saves.

The card scored is the one staged for the row, pared to what this book
reads. The read is every contact in the book, once per screen — the
same bet against growth the contact list makes (`docs/DESIGN.md`, "The
core idea").

## The toggle

Gloss's segmented tabs, above the editor's first field: "new contact",
then "update" and a name for each match. It renders only where there
is a match, a toggle with one side not being a choice.

The sides are links rather than buttons, each a GET of the row's own
screen with `?into=` naming the contact (or nothing, for new). Each
side is its own rendering of the editor — over the arriving card, or
over a contact with the card folded in — with its own fields and its
own etag, so switching is a different screen rather than a state of
the same one, and a screen is what a GET is for. The form carries the
choice back as a hidden `into`.

New is the default. A card that updates a contact changes something
already in the book, and that is a thing for the importer to say
rather than for a score to decide.

## The fold

`Import::Merge` takes the contact's own card as the base, every byte
of it kept, and adds from the arriving card only what the contact does
not have:

- A phone, an email or an address the contact lacks comes in beside
  the ones it has; one it already has (compared the way the match
  compares, and an address by its components) stays single. An
  address one of its groups lends counts as one it has.
- A name, a nickname, a note, a photo — what a contact holds one of —
  fills a gap and never overwrites. Where the two differ, the book's
  own stands.
- A birthday goes into the model where the contact has none, the split
  `Store#put` makes on the way in, and is left behind where it has one.
- The envelope is the contact's own, its UID above all.

What the fold leaves behind is struck on the card as exported beside
the editor, with the lines the import itself drops: "not imported" is
what it is, and a line shown plain there is one claiming to arrive.
Duplicates are not struck — what they say is on the contact already.

Apple numbers a card's `item1.` groups per card, so an arriving line's
group can name one the contact's card already uses. It is renumbered
past all of them, and the label hung off it moves with it — the rule
`Vcf.read` already keeps, that a label goes wherever the line it names
goes.

Everything the fold decided is in front of the importer as an editor,
not applied behind them: the name that stood is in the name boxes,
the phone that came in is a row, and either can be changed before the
Save. That is the walk's whole posture — look at a contact and fix
it — and it is why the default for every clash is the book's own
value rather than a rule clever enough to need explaining.

## The Save

`Import::Write.update`, which is `Store#save_edit` — the contact
editor's own write, so the change log records an edit of that contact
under its own id — then `Store#regroup`.

The groups beside it start from that contact's own, ticked, plus the
group for the import, so the group the walk ends on lists everything
it touched. Everyone's book is not added: whether the contact syncs was
settled before this import, and it is ticked or not as it already is.
The boxes the page loaded with go back as `was[]`, the groups dialog's
own diff (`Web#apply_groups`), so a membership changed elsewhere in the
meantime is left as it is.

The fold is derived again at the Save rather than trusted from the
page, so the etag the form carried refuses a save over a contact that
changed since, as every editor here does. A contact deleted since is
refused outright: writing the card as a new contact instead would be a
different Save from the one pressed.

The row is staged with the updated card after the write lands, not
before as a new contact's is. Until the write, the row is still the
card it arrived as, and a refused or failed Save should come back to
that. After it, the row is saved and names the contact it went into,
like any other.

## Non-goals

- Marking the rows that have a match in the walk's list. Scoring every
  row against every contact on every screen is the cost of the whole
  file times the whole book, per page load, and the row's own screen
  says it when the row is opened.
- Choosing a match automatically, even an exact one.
- Folding field by field — a pick per property. The editor is already
  the place to settle each field, with both cards in view.
- Merging two contacts already in the book. That is a question about
  the book, not the import, and belongs on a contact's own page if
  anywhere.
- Matching on addresses or notes. They identify a household or say
  something about a person rather than naming one.
