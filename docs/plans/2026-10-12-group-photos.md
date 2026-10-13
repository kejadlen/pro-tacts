# Group photos

2026-10-12. A group can carry one photo, meant as a family picture,
shown at the top of the group's own page (`/groups/:id`) and nowhere
else: not on the groups list, not on a member's tags, and never in a
card a client downloads.

## Why not a lent line

Everything in `group_properties` is composed into every member's card
(`2026-08-24-vcard-storage-and-groups.md`), so a `PHOTO` line there
would replace each member's own picture on their devices. The photo
lives in its own table, `group_photos`, keyed by group and cascading
with it, which no composition reads.

## What is stored

The uploaded bytes, as they came: no resizing and no recoding, so no
image library joins the Gemfile or the image. An upload is accepted
when its magic bytes name a JPEG, PNG, or GIF (`Contact.photo_of`, the
same sniff a card's `PHOTO` goes through) and it is at most 10 MB
(`Web::GROUP_PHOTO_LIMIT`). The mime type is read off the bytes on
every read rather than stored beside them.

## Durability

The photo cannot be rebuilt, so `rake db:dump` writes it as
`groups/<id>.<jpeg|png|gif>` beside the group's YAML. It is not in the
group change log: setting or removing one writes no entry, and a
group's delete tombstone does not carry it. The dump's history is the
only record of a photo that was replaced or removed.
