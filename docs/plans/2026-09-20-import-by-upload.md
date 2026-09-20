# Importing by upload

2026-09-20. The middle step of an import — landing a plan's cards on a
host — stopped being a rake task and became a screen in the app. A plan
is still built on the Mac by `rake import:macos:plan` and still
finalized there by `rake import:macos:finalize`; between them, the cards
are uploaded at `/import` and land through the store.

## What was wrong with a task

`rake import:execute` ran on the machine holding the plan and wrote to a
host over HTTP: a PUT per card to `/dav/addressbook/<id>.vcf`, then a
`POST /contacts/<id>/groups`, with `GET /api/groups` in front of each
group it had to make. That meant three things a person had to keep
right, none of which the import is about:

- **A host, named twice.** `data/import/config.yml` had to name the
  server, and the plan recorded which one it landed on so a second run
  could not aim elsewhere. Both facts existed only because the writer
  was somewhere else.
- **A checkout, on the Mac.** Landing needed the repository, the gems,
  and a Ruby, on a machine whose only real job in the import is holding
  Contacts.app.
- **An identity from a proxy.** The cards landed as whoever the host's
  proxy said the request was, which is not visibly the person running
  the task.

Uploading answers all three. The person is already looking at the host
in a browser, already past the identity gate as themselves, and the
machine holding the plan is whichever one they are sitting at.

## What is uploaded

The plan's card files — `data/import/active/<plan>/cards/*.yml` — chosen
in one multi-file picker. Not `plan.yml`, and not the directory: a card
carries everything the server needs, because `Plan.write` names each
file for the id it lands under and writes `sync:*` and the plan's
`import-<timestamp>` group into the card itself. `plan.yml` stays on the
Mac as its own ledger, which is where finalize reads it.

Rack refuses a multipart body of more than 128 parts by default, and a
whole-book plan is 443 cards. `config.ru` raises the limit. The default
guards a public endpoint against a cheap body; this app is on a tailnet
and everyone who can reach it is an admin (docs/DESIGN.md), so there was
nothing there to protect.

## Landing

`Import::Land` writes what `Execute` wrote, through `Store#put` and
`Store#regroup` rather than through the routes those two sit behind. It
is not a second way to write a card — it is the same two writes the PUT
and the groups dialog make:

1. Read every uploaded file first (`Import::Card.parse`), so a card that
   will not read stops the upload with nothing landed. That was
   `execute`'s rule and it survives unchanged.
2. `Store#put` with `client: true` for each card the store does not
   already have, so a card this creates joins everyone's book the way a
   client's create does
   (`2026-09-15-client-creates-join-everyone.md`).
3. `Store#regroup` into the groups the file names, making any that are
   missing, and out of `sync:*` unless the file names it — the same
   reading of a card's groups the browser's own save makes.

A card already in the store is left as it is and reported as such rather
than written over, which is what the PUT's `If-None-Match: *` bought
before. So a plan uploaded twice writes nothing the second time, and a
person who has since edited a contact here does not lose the edit to a
re-upload.

The upload answers with the page listing what arrived rather than the
303 the other writes answer with. Landing is idempotent, so the
re-submission a back button offers writes nothing, and there is no other
page holding what just came in.

## What the plan stopped recording

A contact's status went from none through `landed` and `imported` to
`done`. The two middle states were `execute`'s to write, and the app
cannot write them: it has no plan, only cards. So a contact is now
outstanding until it is `done`, and `Plan#with_status` is
`Plan#outstanding`.

Nothing is lost by it. Finalize already asked the host, card by card,
whether it still had the contact before deleting the original
(`GET /contacts/<id>`) — a stronger check than the status, since the
status only said a write had happened once. That check now stands alone:
a contact whose card is not on the host is kept, which is exactly what a
plan whose cards were never uploaded gets.

`plan.yml` also stopped recording a host, which was `execute`'s guard
against landing one plan on two servers. Uploading is aimed by which
server the browser is pointed at, so there is nothing to guard.
Finalize reads the host from `data/import/config.yml` instead, which is
still the one place a host is named
(`2026-09-19-import-under-data-import.md`).

The plan format did not change, and nothing on disk is rewritten: a plan
`execute` left part way through still reads, and its `landed` and
`imported` contacts read as outstanding, which is what they are.

## The screen

`/import`, linked from the footer beside device setup, for that link's
reason: the dashboard is a search over contacts and a plan is not a
contact. It is rarer than device setup — a plan arrives a handful of
times in a book's life.

The form takes the cards and nothing else. Its answer is a row per card,
linked to the record it landed as, marking the ones that were already
here. A refusal is a toast naming the file: which card would not read,
or which file was not a plan card at all.
