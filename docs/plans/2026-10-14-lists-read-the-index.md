# Lists read the index

2026-10-14. A screen that lists contacts reads them from the
`card_properties` and `card_parameters` index rather than parsing every
stored card, and the import's walk saves its list's rows once, at the
upload, rather than reading every staged card on every screen. Both
came out of measuring allocations per request on a 600-card book with
120 photos of about 80 KB each (PR #28).

## Why

A list shows a name, a phone or two, and an avatar, but the card it
read them from carries the whole base64 picture. On that book
`/contacts`, `/search` and a group's members each allocated over 200 MB
a request, almost all of it the PHOTO lines of cards whose pictures the
list draws as a small avatar, or not at all.

## The listing type

`ListedContact` is what a row, a sort, or a search reads: the
`Contact` readings (name, nickname, organization, birthday, phones,
emails, addresses, notes) over a card written back out of the index's
rows with the PHOTO left out (`Store#listed_contacts`). Its readings
are Contact's own, inherited lines and the composed birthday included,
so a row and the contact's page cannot disagree.

That card is not the stored one, so a `ListedContact` answers no bytes
and no etag: nothing that writes, guards a write, or serves a client
takes one. A screen that does any of those reads the contact whole
(`Store#contact`).

Whether there is a picture is read from the first bytes the index holds
of the card's first PHOTO (`Contact::PHOTO_HEAD`, `Contact.photo_head?`),
enough to know its type, which is all the avatar chooses between a
picture and initials on.

## The import

An upload is split into a file per card under `imports/<id>/original/`
and `revised/`, named by its place in the file, so a screen reads the
one card it shows. The list down the walk's side is a `rows.json` of a
label, a sort key and a count of dropped lines per card, read once at
the upload and again for the one card a Save rewrites
(`Web#import_row`). Matching a card against the book reads the
listings, then reads the best match whole, since that is the one a
merge writes into.
