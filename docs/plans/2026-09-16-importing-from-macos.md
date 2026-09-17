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
| `plan.json` | The source, when it was built, the group, and each contact's minted id beside its source id; then the host, the group's id, and each contact's status |
| `cards/<id>.vcf` | The bytes `execute` PUTs, byte for byte |
| `backups/<id>/` | The original, in whatever files the source reads it as |

The builder writes the cards and backups once and nothing rewrites them.
A plan has no open questions in it: every card is final when the plan is
written, so `execute` runs it rather than finishing it.

`plan.json` also records how far `execute` and `remove` have carried the
plan, saved after every step. A contact's status goes from none to
`landed`, `joined`, and `removed`. Each save writes a new file and renames
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

`rake import:execute PLAN=dir HOST=host` does the following, recording
each step in the plan:

1. PUT each card to `/dav/addressbook/<id>.vcf` with `If-None-Match: *`.
2. Create the plan's group, `import-<timestamp>`, through `POST /groups`.
3. Join each card to it through `POST /contacts/<id>/groups`.

A rerun skips every step the plan records. The plan alone is not
enough, because a run can die after a write lands and before the plan
records it, so each step also accepts its own earlier success from the
host. Skipping
first keeps a rerun from collecting refusals, each of which warns Sentry
(`RefusalAlerts`).

- A bare 412 to the PUT is `If-None-Match` failing, and at 48 bits a
  minted id is taken only by this plan's own earlier PUT, so the card
  counts as landed. A 412 with a body is the card refused.
- The group is looked up by name in `GET /api/groups`, every group's id
  and name as JSON, before it is created. A name that is already there
  is this plan's, since it carries the plan's timestamp.
- Joining a group twice is joining once (`Store#add_member`).

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
grants access to whatever terminal runs it. It serializes each contact
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

The macOS builder turns each line into a card line through a `case` on
the property name, whose `else` records the line as unknown. Each branch
names the parameters it accepts, and a parameter outside that list is
unknown too. Once every contact in the batch is read, any unknown fails
the build with every unknown name, its count, and a few source ids, and
no plan is written. A small batch needs only the branches its own
contacts use.

The `case` starts empty. A property earns a branch when a build refuses
it, and the branch is written with that property in view, so nothing is
imported on the strength of a guess about what it holds. Parameter
values such as `TYPE=IPHONE` are not checked: the server passes `TYPE`
through, and Apple wrote them.

## Removing the originals

`rake import:macos:remove PLAN=dir` deletes, through `CNSaveRequest`, the
contacts this plan landed. For each one it first GETs the card from the
host the plan names, then reads the contact again and compares it to its
backup, note included, and skips it, printing why, if either check
fails. A contact edited on the Mac since the plan is kept, and so
is one whose card is no longer on the host. A contact already gone from
the Mac counts as removed, so a rerun is safe for the same reason
`execute`'s is.

The comparison is exact because CNContact exposes no modification date.
A contact Contacts.app touched on its own will be skipped, which is the
safe direction to be wrong in.
