# A contact can carry a Signal handle

2026-10-18. A Signal username had nowhere to go: no property this book
reads holds one, and the importers dropped the line a client would
write it as. `Contact` grows `#handles`, read off `IMPP`; the record
card shows each one under its service, and the editor edits a handle
and its service both, any service rather than Signal's alone. No card
already in the store is rewritten.

## The line is Apple's

A handle is written as

```
IMPP;X-SERVICE-TYPE=signal:x-apple:alice.42
```

`IMPP` is the property for an instant-messaging address (RFC 6350
section 6.4.3; RFC 4770 gave it to 3.0, the version this book serves).
Its value is a URI, and Signal has no scheme for a username: a
`signal.me` link encodes the name rather than spelling it. Contacts.app
writes a service it has no scheme for under its own `x-apple:` scheme,
the service's name in `X-SERVICE-TYPE` — the spelling the import
fixture's `X-SOCIALPROFILE;type=twitter:x-apple:incompleteness` shows
the same client using for a profile. Writing the client's own spelling
is what lets it show the line as a Signal handle rather than keep it as
a property it has no field for.

The service is written as it was typed, and lowercase where this server
picks it — the Monica import's `signal` — as that fixture's
`type=twitter` is and as the screens caption every other kind. The
reader shows a service in whatever case the card carries it, so a
handle Contacts writes as `Signal` reads as that.

The alternative was a property of our own, `X-SIGNAL:alice.42`. A
client keeps an X- property it does not know (RFC 6352 section
6.3.2.2), so it would round-trip, but no client would show it, and a
handle typed into Contacts would arrive as `IMPP` regardless — the
phone labels' reason for reading the client's form rather than
inventing one (`2026-09-18-phone-labels.md`, "A label is a line, not
a parameter").

The spelling, its case included, is inferred from that fixture and
from how Contacts writes the services it does know, not recorded from
a session that added a Signal handle. The first one recorded settles
it; if Contacts spells it otherwise, `Contact.handle_line` and the
reader change and the lines this server wrote are migrated to match.

## Every IMPP reads, not only Signal's

The reader takes every `IMPP` line: the service from `X-SERVICE-TYPE`,
the handle from the value after its scheme, and the scheme itself kept
on the row so that an edit writes it back. A save swaps only the handle,
under the line's own header and scheme, the way a phone's save keeps
its `TYPE` parameters (`2026-09-05-web-card-editor.md`). A line whose
value has no scheme is no handle and reads as none; the card still
carries it.

Reading them all costs nothing over reading Signal's alone, and the
lines Apple already sends for the services it does know show instead of
staying invisible.

## The service is the row's

The first cut offered `signal` in the add dialog and wrote that service
into every handle it added. A dialog naming services is a list
someone has to keep, one entry per messenger in use, so the row
carries its service as a field of its own instead: a handle row is two
fields, the service and the handle, the address row's shape at a
smaller size.

A blank handle removes the line; a service alone is nothing to reach
anyone at. A changed handle under the same service swaps under the
line's own header and scheme. A changed service rewrites the header,
keeping the line's group and every other parameter, and puts the handle
under `x-apple:`: the line's old scheme belonged to the old service
(`xmpp:` is no Signal address), and `x-apple:` is the scheme Contacts
writes for a service it has none for. A blank service writes no
`X-SERVICE-TYPE`, and the row reads as a bare handle.

## What comes in on import

`IMPP` joins the properties an uploaded `.vcf` keeps (`Import::Vcf`)
and the ones a merge holds many of (`Import::Merge`), so a handle on an
arriving card is no longer struck. Monica ships no Signal field type; an
account that made one files a handle under its name, and that field is
written as the line above.

Monica's other social fields — Facebook, Twitter, a type an account
made up — stop being written at all. They came in as `X-SOCIALPROFILE`
lines whose one use was to be struck on the import screen, left behind
in view (`2026-09-25-importing-from-monica.md`, "Left behind, in
view"). Once a handle has a field, the profiles left over were judged
not worth a struck row each, this book having no field for them. A
vCard that carries its own `X-SOCIALPROFILE`, as Apple's and Monica
5's do, is the card's own line, and is still struck like any other
property this book does not read.
