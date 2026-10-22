# Perceived speed

2026-10-22. The admin still felt slow after the listing and search
work (`2026-10-14-lists-read-the-index.md`,
`2026-10-17-search-keys.md`). Most of what a phone waited for was
pictures sent again on every visit. The rest was the contact page
building the whole book to name five people in a tooltip.

## How it was measured

The book is the 1,000-card shape from the search keys record: 200
cards with a 60 KB JPEG, birthdays on half, and three groups beside
`sync:*` (4, 40 and 120 members). The app ran under Puma from
config.ru. Server times are the median of nine curl requests. Page
loads are Chromium at phone width over an emulated link (40 ms
latency, 10 Mbit/s down), loaded once cold and once again.

## Pictures

The photo route sent the whole picture every time. It set an ETag but
never compared it, and it sent no Cache-Control. /contacts draws an
avatar for every card with a picture, and the browser fetched all of
them before the page counted as loaded.

The route now sends `Cache-Control: private, no-cache` and an ETag of
the picture's own bytes. Roda's caching plugin answers a picture the
browser already holds with a 304. `no-cache` means the browser stores
the picture but asks before reusing it, so a replaced picture shows
straight away. The ETag is the bytes' digest rather than the card's,
so editing a phone number does not resend the picture. Avatars are
`loading="lazy"`, so only the ones near the screen are fetched.

## Compression

`Rack::Deflater` gzips `text/html`, `text/css` and `text/javascript`
for a browser that asks. /contacts is 500 KB of markup and gzips to
16 KB. DAV responses (XML and cards) and pictures are left alone:
the clients were confirmed against the bytes as they are
(`docs/carddav.md`), and a JPEG is compressed already.

## The contact page

A contact's group tags name each group's first five members on hover
(`Admin::GroupTag`). To pick those five, `Store#listed_groups_of`
listed every member of every group the contact is in, and every
contact is in `sync:*`. So each contact page built all 1,000 listed
contacts.

`sort_keys` (migration 015) holds each card's `Contact#sort_key`,
written by `Store#reindex` like its search key. A group's first few
members are now a query ordered by that key and then the id, which
is `Contact#<=>`'s order: SQLite compares text bytewise, the same as
Ruby. A group lends no name, so the stored card alone decides the
key. `ListedGroup#first_members` holds those few, and the tag counts
the rest from `#members`.

## The listing itself

Three costs were paid for every listed contact:

- `VCard.header_of` compiled a regexp for every parameter. It is now
  `Parser::BARE`, built once.
- `VCard#property` walked every property for each lookup. It now
  reads a table of each name's first property.
- `Store#listed_by_id` wrote the indexed rows out as text and then
  parsed that text again. It now passes each line with the property
  it came from (`VCard.of`), and `VCard#insert` keeps that reading
  when it adds the birthday and lent lines. The property test for
  `header_of` is what makes this safe: a rendered header reads back
  as the property it came from.

A group's page listed the whole book so that its change log could
name cards. It now lists the members plus the cards the log names.

## Results

Server, median ms:

| Page | Before | After |
|---|---|---|
| `/contacts/:id` | 215 | 23 |
| `/contacts` | 278 | 178 |
| `/groups/:id`, 4 members | 74 | 11 |
| `/groups/:id`, 120 members | 103 | 35 |
| `/groups/:id`, `sync:*` | 219 | 157 |
| `/` | 28 | 27 |

Page load over the phone link (load event, bytes transferred):

| Page | Before, any visit | After, first visit | After, again |
|---|---|---|---|
| `/contacts` | 10.6 s, 12.2 MB | 0.47 s, 368 KB | 0.48 s, 16 KB |
| `/contacts/:id` | 0.31 s, 69 KB | 0.08 s, 62 KB | 0.08 s, 4 KB |
| `/groups/:id`, 120 members | 1.36 s, 1.3 MB | 0.08 s, 240 KB | 0.07 s, 5 KB |

## What is left

/contacts and the `sync:*` group page still build every listed
contact, about 80 ms of their time on this book, and render a row for
each. Making that cheaper would mean keeping listed contacts between
requests, keyed on the change log. That cache would go stale if
anything wrote the index without logging, such as `rake
index:rebuild` run beside a live server. It was left out.
