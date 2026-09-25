# One note per contact

A contact carries one `NOTE`, stored and served, and what a group
lends rides inside it as a labeled section. The invariant replaces the
two-line shape composition used to serve, which macOS silently truncated
(`docs/apple-contacts.md`, "Only the last of two notes survives"): the
client keeps the last of two `NOTE` lines and drops the rest on its
next write, and composition appends a group's after the member's own —
so the member's own note was not just hidden but lost, because a PUT
stores the submission minus what its groups lend.

Reordering the composition cannot fix that. A lent line absent from a
submission reads as a deliberate deletion and propagates to every
member (`EditedContact`, the decided semantics of
`docs/plans/2026-09-09-group-edits-propagate.md`), so serving the
group's note first would have one member's macOS edit delete the
shared note for the whole group. Joining is the only shape where both
survive and the group's part is still present to attribute.

## The served shape

```
NOTE:gate code 1854
call before visiting

Shared · Neighbours:
bins go out on Tuesday
```

The member's own text first, then one section per lending group, in
inheritance order: a blank line, the header `Shared · <label>:`, one
newline, the body. The label is the group's label — names are unique
(`db/migrations/008_group_names.rb`), and a nameless group's label is
its id — and the header is composed, never stored: the group's row
keeps its bare `NOTE:` line, so the group editor and the propagated
edit both keep working on bare text, and the split strips the header to
recover the line.

The header must live in the text value because nowhere else survives
the client: macOS drops the `X-PT-GROUP` parameter on `NOTE`
(`docs/apple-contacts.md`), and a property parameter cannot carry a
provenance the client rewrites away. Words rather than a symbol or
emoji, because a marker that explains itself is edited as content
rather than deleted as cruft, and a deleted header is a mangle (below).
It also reads as prose to someone in Contacts, which is where it is
seen.

The composer writes the shape exactly one way, so an untouched
round-trip reproduces the composed bytes and the PUT answers a strong
etag. The split tolerates what a user's editing does to whitespace
between sections — blank lines added or removed — because headers, not
separators, are the structure.

`Shared · ` is rare enough at line start that a collision needs the
member's own text to open a line with the phrase plus a lending group's
label. Two sections claiming one label (a collision, or two groups
whose labels coincide) is a mangle; a section for a label nothing
lends — stale text from an old mangle — is not a header at all, just
member text.

## The split

A PUT's `NOTE` is read against what the contact's groups lend:

- A section under a lending label, unchanged — struck, no group edit.
- Changed — a `GroupEdit` carrying the bare line, the section's text
  rewritten through the text writer. The one loss is parameters: a
  group `NOTE` carrying `TYPE` or the like loses them through a
  propagated edit, the editor never having written them.
- Absent — the deletion `GroupEdit`, the same semantics a deleted lent
  line has. Clearing the whole field in Contacts therefore deletes the
  group's note for every member and the member's own with it: parity
  with before, where clearing the field deleted the lent line.
- No NOTE at all in the submission — every section is absent: the
  deletions above, and no stored note.
- No headers while groups lend, a header mangled, or two sections
  claiming one label — the mangle: the whole value stays on the
  member's stored note, no group row is touched, and an arrival report
  says so. The group keeps lending, so the next serve shows its note
  as a fresh section beside the text the member absorbed — duplication
  rather than loss, visible, reported, and rare.

The member's remainder — everything outside the sections — is the
stored note, or none when it is blank. Where a group lends nothing the
NOTE lines are the member's own and keep their bytes: nothing joins,
and a card that never met a group serves exactly what it stored.

## The invariant

At most one `NOTE`, on a stored card and in a group's lines. Foreign
input that breaks it is joined, not refused — a client's two-`NOTE`
submission or an imported card with several joins into one value,
blank line between, and reports as a broken assumption the way the
BDAY reports do. What raises is our own bug: a stored card or group
lines built carrying more than one `NOTE` raise at the write, and the
raise reaches Sentry with the request. A migration joins the cards and
group rows already stored, so the invariant is true of the data the
day it lands.

Import holds the same rule: an arriving note fills a gap
(`Import::Merge`'s ONE), and several arriving join into the one the
same way.

## What the admin screens read

The composed value is for clients. The admin card keeps showing the
member's note and each group's as their own provenance-marked rows,
read off the contact's own card and its inheritance rather than parsed
out of the joined value — the same separate-standing the editors
already have (`Contact#own`).

## Probes outstanding

Two round-trips are asserted by tests against this server's own
composer and not yet observed from a client: a multiline `NOTE`
through an unrelated macOS edit, and the same on iOS. Each becomes an
exchange step when recorded, and an `docs/apple-contacts.md` entry
either way.
