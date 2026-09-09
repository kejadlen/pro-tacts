# A read-only collection: the advertisement first

2026-09-09. Task xownmrus, "make the collection read-only to clients so
the web editor is the only write path", stopped one step in. The
collection now advertises `DAV:read` alone; PUT and DELETE still answer
exactly as they did. That is deliberate, and this doc is why.

## The lever

`docs/macos-contacts.md`, "Writes are gated on the advertised privilege
set": macOS Contacts asks for `DAV:current-user-privilege-set` on the
collection in every `Depth: 1` poll and attempts no write while the
server omits it. Adding `write`, `bind`, and `unbind` on 2026-08-24
produced a queued `PUT` within a second of the first response carrying
them — an edit made four hours earlier, which the client had been
holding all along.

So the advertisement is not a hint the client takes alongside other
signals. It is the gate. `Allow` is not: Contacts sends `OPTIONS` to
the principal and never to the collection, so it never learns which
methods the collection accepts (same doc, verified 2026-08-24).

Dropping the three back out of `Web`'s PROPFIND answer is therefore the
whole client-facing switch, and it is the only change here.

## The question that decides the rest

Withholding a privilege has only ever been observed in one direction:
the server omitted the property entirely, the client wrote nothing, and
nobody watched the UI while it did. What a client does when it is *told*
the collection is read-only is unobserved. Two shapes, and they are not
the same feature:

- The client greys editing out. A contact opened from this account is
  visibly not editable, and the web editor is the only place a change
  can be typed. That is the outcome the task wants.
- The client lets you type, accepts the edit locally, and discovers the
  refusal afterwards. Then every edit made on a device is a change the
  user believes they made, queued against a server that will never take
  it — and the same doc's "Pending writes queue indefinitely and retry
  on their own" says the client holds such an edit for hours, replaying
  it every few minutes. Silent, permanent divergence between the phone
  and the book.

The second is worse than the status quo, where a device edit at least
lands. It cannot be reasoned out of the RFCs — RFC 3744 says what the
property means, not what a client renders — so it has to be watched.

## Why the change lands before the answer

Because the observation needs a server that serves it. A client cannot
be watched reacting to a read-only privilege set until the collection
advertises one, so this is the setup for the experiment rather than a
result acted on. Run `rake dev`, point macOS and iOS Contacts at it, and
open a contact.

Both clients, separately. iOS has been a second client on every question
it was asked (`test/fixtures/ios-exchange/`), and it is the one that
sends DELETE at all.

The enforcement half — trimming `Allow`, and 403-ing PUT and DELETE with
a `DAV:need-privileges` body (RFC 3744 section 7.1.1), marshalled the way
the unsupported-REPORT 403 is — is left undone on purpose. It is what
you build once the answer says the outcome is the first shape, and
building it now would hide the interesting case: with the routes still
answering, a client that ignores the advertisement and writes anyway
still writes, and that is itself the observation.

## What the enforcement half will have to settle

Two things found while reading for this change, recorded so the next
pass does not rediscover them.

**A refused write is not an unhandled request.** `UnhandledRequests`
captures 403 (`unhandled_requests.rb:29`) because 403 is today the
routed-but-unimplemented case, an unsupported REPORT type. A read-only
collection makes 403 the ordinary answer to every client write, which is
not news about missing functionality — it is the feature working. Worse,
the capture would not settle: the directory name carries a digest of
method, path, and body, and the retrying client refreshes `REV` on every
replay, so each retry hashes differently and gets a directory of its
own. `test/fixtures/macos-exchange/` steps 10 and 11 are exactly that
pair, two captures of one edit, promoted from `log/unhandled`. Every few
minutes, for hours, per pending edit. The record is not wanted on those
terms; the capture rule needs to stop treating a deliberate refusal as an
unanswered request before the 403s land.

**The write path has no other caller.** 403-ing the routes leaves
`Web#write_card`, `Web#remove_card`, and `Store#delete` unreachable —
the web editor's `apply_edit` shares nothing with them, and `Store#put`'s
only other caller is the editor's create. About thirty-five tests in
`test/pro_tacts/test_web.rb` reach that path over HTTP, along with macOS
fixture steps 10 and 11 and iOS steps 05 and 06. Deleting the path or
keeping it unreachable is a real choice, not a tidy-up, and it belongs to
the pass that has the answer above.

`PUT` and `DELETE` stay in `config/puma.rb` throughout. Puma's
`supported_http_methods` replaces its default list rather than extending
it, so a method missing from it is a 501 out of the HTTP parser, before
Rack — the request never reaches the app, and nothing records that a
client tried.

## Non-goals

- Removing the privileges from `DAV:supported-privilege-set`. The
  property is not served at all; nothing has asked for it.
- `DAV:read-current-user-privilege-set` (RFC 3744 section 3.7), for the
  same reason.
- Any change to the web editor. It was already the write path this task
  wants to be the only one.
