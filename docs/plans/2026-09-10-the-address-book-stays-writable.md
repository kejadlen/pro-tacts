# The address book stays writable to clients

2026-09-10. The question was whether the CardDAV collection could be
made read-only to clients, so that the web editor would be the only way
a card changes. On macOS it cannot. Every way of saying "read-only"
that the protocol offers leaves Contacts either editing locally or
showing nothing, so the idea is dropped.

## Every lever fails on macOS

A client learns what it may do from `DAV:current-user-privilege-set`
(RFC 3744 section 5.4) on the collection. `docs/apple-contacts.md`
records what Contacts does with each form the property can take:

| Server advertises | Contacts does | Recorded under |
|---|---|---|
| No privilege set | Syncs the cards, accepts edits locally, never sends them | "Writes are gated on the advertised privilege set" |
| `read` only | Lists the cards, fetches none, shows an empty account | "Advertising only `read` stops the sync" |
| All four, then refuses the PUT | Keeps the edit and resends it every few minutes, for hours | "Pending writes queue indefinitely and retry on their own" |

The first leaves every Mac holding edits the server never sees. The
second is not an address book. The third was not run with the 403 that
RFC 3744 section 7.1.1 would have it send, but the refusals that were
observed got retried rather than given up on, and a queued edit is the
first lever's divergence plus the traffic.

No form greys out editing, which is what a read-only collection would
need from the client.

## What stays as it is

The collection keeps advertising `read`, `write`, `bind`, and `unbind`,
and PUT and DELETE stay answered (`ProTacts::Web`). Contacts remains a
write path beside the web editor, so what exists to reconcile the two —
subtracting inherited lines from a submission, and propagating edits to
shared attributes back to their group
(`2026-09-09-group-edits-propagate.md`) — is still needed.

## Not tested

iOS Contacts has not been tried with any of the three. It cannot reverse
this: as long as one family member syncs from a Mac, the web editor
cannot be the only write path.
