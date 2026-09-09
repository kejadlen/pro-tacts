# A read-only collection, and why the privilege set cannot be one

2026-09-09. Task xownmrus, "make the collection read-only to clients so
the web editor is the only write path", tried and abandoned the same day.
The code is back where it started. This is the record of what was tried,
what the client did, and why the approach is not worth a second attempt.

## The premise

`docs/macos-contacts.md`, "Writes are gated on the advertised privilege
set": macOS Contacts attempts no write while the server omits
`DAV:current-user-privilege-set`, and adding `write`, `bind`, and
`unbind` on 2026-08-24 produced a queued `PUT` within a second of the
first response carrying them — an edit made four hours earlier. `Allow`
is not the gate; Contacts sends `OPTIONS` to the principal and never to
the collection.

So the task's reasoning was that dropping the three back out is the whole
client-facing switch, and the enforcement half — trimming `Allow`, 403ing
PUT and DELETE with `DAV:need-privileges` — is defense behind it.

One question was open: whether the clients grey editing out on a
read-only privilege set, or let you type an edit that fails afterwards.
Only the write direction had ever been watched.

## What was tried

The advertisement alone. `DAV:read` was served in place of the four, and
nothing else moved: the PUT and DELETE routes still answered, `Allow`
still named them, `config/puma.rb` still passed them. Deliberately, so
that a client which ignored the advertisement and wrote anyway would
still land its write rather than lose it — and so the interesting case
stayed visible instead of being masked by a 403.

That staging is what saved the first edit made against it.

## What the client did

It forked the contact. An edit produced a `PUT` creating a *second*
contact at a new href with a new `UID`, carrying the change, and left the
original untouched.

Not a stale cache: the client asked for the property five times inside
three minutes and was answered `read` alone every time, the fork
following those answers. Not the reseed re-push that a rebuilt dev
database provokes either — no `410 DAV:valid-sync-token` appears in the
session, so nothing resynced from scratch.

Three states have now been served, and they give three behaviors:

| Advertised | What an edit does |
|---|---|
| Property absent | Accepted locally, queued silently — four hours, never sent |
| `read` alone | Forks: a second contact carries the edit, the original is untouched |
| `read`, `write`, `bind`, `unbind` | Updates in place |

The privilege set is therefore read for its content, not merely its
presence — which was the other hypothesis, and it is dead too.

## Why the approach is abandoned

None of the three states greys editing out, and the open question turns
out to have had a third answer nobody proposed. Ranked by what a user
loses:

- `read` alone is the worst state available. The fork is silent, the
  contact the user edited still shows the old value, and a synced book
  gains a duplicate per edit. Strictly worse than writes landing.
- Omitting the property is the only state that stops writes, and it stops
  them by having the client hold the edit forever without saying so. The
  device and the book diverge silently. Better than duplicates, still not
  read-only in any sense a user would recognize.
- Advertising all four — the status quo, restored — at least means an
  edit made on a device is an edit that arrives.

Adding the enforcement half does not rescue any of this. 403ing the PUT
would refuse the fork's create, but the duplicate is already on the
device by then: the client would keep a contact it can never sync and
retry it every few minutes for hours. The refusal arrives after the
damage, which is the shape of the whole problem.

"The web editor is the only write path" is not reachable by telling the
client anything. It would need the client not to have the account, or the
server not to be reachable by it — a different task, and not this one.

## What was learned that outlives the attempt

- The three-state table above, now in `docs/macos-contacts.md` under "A
  read-only privilege set forks the contact", with the privilege list in
  `web.rb` carrying a note so the trim is not attempted again.
- The client re-asks for the privilege set continuously — five times in
  three minutes — rather than caching it from account setup. The recorded
  sessions in `test/fixtures/` each hold exactly one bootstrap PROPFIND
  asking for it, which reads as "asked once at setup" and is wrong. A
  fixture session is a slice, not a duty cycle.
- Two things the enforcement half would have had to settle, if it is ever
  revived for another reason. `UnhandledRequests` captures 403
  (`unhandled_requests.rb:29`), and a deliberate refusal is not an
  unanswered request; worse, the directory name digests the body, and the
  retrying client refreshes `REV` on every replay, so each retry lands a
  directory of its own — `test/fixtures/macos-exchange/` steps 10 and 11
  are one edit captured twice. And 403ing the routes would orphan
  `Web#write_card`, `Web#remove_card`, and `Store#delete`, along with the
  thirty-five tests in `test/pro_tacts/test_web.rb` that reach them over
  HTTP.
