# Importing from macOS Contacts

2026-09-16. Contacts on this Mac move into a pro-tacts host in three
steps, each a rake task: build a plan from the Mac, execute it against a
host, and remove the originals from the Mac. Monica gets an importer of
its own later, and the two share everything but the first and last
steps.

## A plan is what will happen, and how far it got

A plan is a directory under `data/imports/`, which is ignored, since it
holds every contact in full:

| Path | Holds |
|---|---|
| `plan.yml` | The source, when it was built, the group, and each contact's minted id beside its source id; then the host and each contact's status |
| `cards/<id>.yml` | The contact's fields and the groups it belongs to, for a person to edit before `execute` |
| `backups/<id>/` | The original, in whatever files the source reads it as |

The builder writes the cards and backups once, and no code rewrites
them. A person can: a card file is the plan's one open question, read as
it stands when `execute` carries it.

`plan.yml` also records how far `execute` and `remove` have carried the
plan, saved after every step. A contact's status goes from none to
`landed`, `imported`, and `removed`. Each save writes a new file and renames
it over the old one, so a run that dies mid-save leaves the plan as the
step before left it. `execute` records the host before its first write
and refuses a `HOST` other than the one recorded, so one plan cannot
land on two servers.

Companies are not imported. A contact whose `contactType` is
`organization` is left out of the plan, so `remove` never touches it
either.

A plan can cover part of the book, so an import can be tried a few
contacts at a time: `rake import:macos:plan LIMIT=n` plans the first n
people, companies skipped. First means Contacts.app's own list order,
`CNContactSortOrderUserDefault`; the fetch request's default is
`CNContactSortOrderNone`, which promises no order at all
(`CNContactFetchRequest.h`). Plans keep no record of one another. The
next plan's first n are new because `remove` took the last batch off the
Mac, so a contact that landed and was not removed
lands again, as a second card, from the next plan that includes it. Each
plan is its own group.

Every card gets a freshly minted id, which is also its `UID`: twelve
letters from `ChangeId.mint(12)`, the width the web create mints. A
source's own identifier is never reused on the server; the plan carries
it beside the minted id, and that pairing is how `remove` finds the
original.

## Execute is the same for every source

`rake import:execute HOST=host` lands the oldest plan in `data/imports`
with a contact still to land or still to be put in its groups, and
`PLAN=dir` names another. Plans are carried in the order they were
built, so the one to take further is the oldest not taken there yet —
the rule `remove` picks by too. It does the following, recording each
step in the plan:

1. Read every card not yet imported, and stop before any write if one
   will not read.
2. PUT each card to `/dav/addressbook/<id>.vcf` with `If-None-Match: *`.
3. Put each card in the groups its file names through
   `POST /contacts/<id>/groups`, creating any that are missing through
   `POST /groups`.

A rerun skips every step the plan records. The plan alone is not
enough, because a run can die after a write lands and before the plan
records it, so each step also accepts its own earlier success from the
host. Skipping
first keeps a rerun from collecting refusals, each of which warns Sentry
(`RefusalAlerts`).

- A bare 412 to the PUT is `If-None-Match` failing, and at 48 bits a
  minted id is taken only by this plan's own earlier PUT, so the card
  counts as landed. A 412 with a body is the card refused.
- A group is looked up by name in `GET /api/groups`, every group's id
  and name as JSON, before it is created, so a rerun reuses the group an
  earlier run made.
- Joining a group twice is joining once (`Store#add_member`).
- A PUT that creates a card makes it a member of `sync:*`
  (`2026-09-15-client-creates-join-everyone.md`). The request that sets
  a card's groups therefore lists `sync:*` among the groups it was
  already in, so a card whose file does not name `sync:*` is taken back
  out of it.

## A card is a form filled in

A card file holds what the web editor would: a first and last name and
a list of phone numbers, plus the names of the groups it belongs to. The plan
writes `sync:*` and its own `import-<timestamp>` group into every card,
ahead of any the builder chose.

```yaml
first: Ada
last: Lovelace
phones:
- "+12532189075"
groups:
- sync:*
- import-20260916T180412Z
```

`Import::Card` turns the fields into a contact through the web's own
code: `CardForm.new_card`, then `CardForm.contact_card` with each phone
as an add row. A phone's types do not survive, because the form has no
field for them, so a number lands as a bare `TEL`.

A file that will not read as a card is refused, naming the file: a
missing or unknown key, a name with neither half, or a value YAML reads
as something other than text. An unquoted `no` is false and an unquoted
`+12532189075` is a number, and either would otherwise import as
something no one typed.

`HOST` is a base URL, such as `https://contacts` or the dev server's
`http://localhost:9292`.

These are the routes a client and the admin UI already use, so the
server gains nothing for this. The host's proxy supplies the identity,
and a PUT that creates a card also puts it in the writer's `sync:` group
(`2026-09-12-per-user-books.md`). `HOST` has no default and is not
`PRO_TACTS_HOSTNAME`, which names the host a profile points at and is
usually a different one.

## Reading the Mac

`script/macos-contacts.swift` reads through Contacts.framework, and TCC
grants access to whatever terminal runs it.

It reads the iCloud account alone, card by card. This Mac's Contacts
holds four accounts: iCloud (443 cards), Monica (1,679), and two
pro-tacts accounts, the deployment and the dev server. By default the
framework merges cards linked across accounts into one contact under an
identifier no card has; 344 of the 1,801 contacts it returned were
merges. AppleScript knows no such identifier, so a merge's note cannot
be read, and a delete could not name it. Reading the iCloud container
with `unifyResults` off gives each card under the identifier AppleScript
uses, and keeps Monica's cards for the Monica importer and pro-tacts
from importing itself. The reader still fails on any card AppleScript
does not list.
 It serializes each contact
with `CNContactVCardSerialization`, which leaves out three things on this
Mac with no error for any of them (measured 2026-09-16 over 1,799
contacts, macOS 26):

- `NOTE`. The framework strips `CNContactNoteKey` from the fetch of a
  process without Apple's notes entitlement: `isKeyAvailable` is false,
  and reading `note` raises `CNPropertyNotFetchedException`. AppleScript's
  `note of person` returns the note, so notes come from there.
- `PHOTO`. The image key comes back available, and still no card carries
  a photo, so the builder writes `PHOTO` from `imageData`.
  `imageDataAvailable` is true for 392 contacts while `imageData` is
  present for 193; which of the two to believe is unsettled.
- `UID`. No card has one, so the builder adds the minted id.

The reader asks for an explicit list of keys and fails if any comes back
unavailable, so the next silent strip stops the read rather than a
contact losing a field.

A contact's backup is the serialized vCard, every fetched key as JSON
with image data in base64, and the AppleScript note.

## The builder knows only what it was taught

The macOS builder decides each line through a `case` on the property
name, whose `else` records the line as unknown, then fills the card's
fields from the lines it kept. The envelope is dropped, since the web's
create writes its own; a `VERSION` other than 3.0 is unknown. An Apple `PRODID` is
dropped, since Contacts writes its own on every save. The note and the image
data, which the vCard leaves out, are unknown until a branch takes them
too. Each branch
names the forms it accepts, a form being the group, name, and parameters
spelled exactly as the source wrote them, and a line in any other form is
unknown under that form. Once every contact in the batch is read, any unknown fails
the build with every unknown name, its count, and a few distinct values
it held, each beside its source id and cut short when long, and
no plan is written. A small batch needs only the branches its own
contacts use.

The `case` starts empty. A property earns a branch when a build refuses
it, and the branch is written with that property in view, so nothing is
imported on the strength of a guess about what it holds. Parameter
values are part of the form, so `TYPE=IPHONE` is refused until a branch
names it. A property whose value has a shape can check it too: `TEL`
takes only a `+` and digits.

A field holds less than a line can, so a line that would lose something
on the way into one is unknown too. The name comes from the one `N`,
and is refused when `N` holds more than a family and given name, or when
the one `FN` is not those two joined with a space, the way the web
editor writes it.

## Removing the originals

`rake import:macos:remove` deletes, through `CNSaveRequest`, the contacts
the oldest landed plan imported, and `PLAN=dir` names another. The host
is the one that plan recorded rather than a `HOST`, the contacts to take
off this Mac being the ones already carried somewhere. For each one it
first asks that host's card browser, `GET /contacts/<id>`, whether it
still has the card — the DAV collection serves the asking user's book
alone, and a card in no `sync:` group is on the host and in no book —
then reads the contact again through
`macos-contacts.swift show` and compares it to its backup, note
included, and keeps it, printing why, if either check
fails. A contact edited on the Mac since the plan is kept, and so
is one whose card is no longer on the host. A contact already gone from
the Mac counts as removed, so a rerun is safe for the same reason
`execute`'s is. The deletes go in one `CNSaveRequest`, since each one
starts the script again, and the statuses are recorded after it: a run
that dies between the two finds those contacts gone next time and
records them then.

The comparison is exact because CNContact exposes no modification date.
A contact Contacts.app touched on its own will be kept, which is the
safe direction to be wrong in.
