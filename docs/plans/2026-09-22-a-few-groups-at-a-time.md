# A few groups at a time

2026-09-22. The groups dialog on a contact's card
(`Admin::GroupDialog`) stops rendering its whole list visible. Eight
rows stand shown; the rest are in the page, hidden, and the filter or
one button brings them out. Nothing about what the dialog posts or
what the save does with it changes.

## Why a cap

The dialog is a popover, and a popover here does not scroll: Gloss
gives `dialog` `height: fit-content` and `overflow: hidden`, and
admin.css adds a header, a body and a footer to that without a
max-height anywhere. One checkbox per group was fine at four groups
and is the dialog's whole problem at forty — the body grows until the
element runs out of viewport, and what is clipped off the bottom is
the footer holding Save. There is no scrollbar to reach it with. The
list is the wrong shape for reading either way: a name is found by
typing it, which the filter has always been there for, not by eye down
fifty rows.

## Why the rows stay in the page

The filter is client-side, matching `data-label` on rows the server
rendered (see `GroupDialog`, and the reason the label is a data
attribute rather than script). So a group left out of the page is a
group the dialog cannot reach at all: the filter would answer "No
groups match" for a group that exists. A hidden row costs a few
bytes, keeps the filter total, and keeps submitting its box.

That the box still submits is not what protects membership, though.
The save is a diff of what came back against what the page loaded
(`was[]`, `Web#apply_groups`), so a group in neither list is one the
save says nothing about. Rendering every row is for reachability;
membership is safe either way, and would be safe under a
server-side limit too. What would not survive one is the filter, so
the cap is a matter of visibility only.

## The groups a contact is in are never capped

They sort where their names sort, but they are always shown. Those are
the boxes the dialog is opened to untick, and a contact's card lists
its groups right above the button that opens it — a dialog that
hides one is a dialog disagreeing with the page it came from. So they
take rows from the limit rather than standing outside it, and the
opening list is eight rows or the contact's memberships, whichever is
longer. A contact in thirty groups sees thirty, which is a list they
made themselves.

## What lifts it

Two things, and they are not the same gesture:

- Typing in the filter. The cap lifts for the duration, so a match
  behind it shows like any other. This is the path for a group whose
  name is known, and it is one action rather than two.
- `show all N groups`, under the list. This is the path for looking
  rather than naming, and it names the whole count because that is
  the number a person is deciding whether to read. It stands down
  while the filter has anything in it, the cap being lifted already,
  and the dialog re-renders on every open, so the list comes back
  capped next time.

## Non-goals

- Paging. A cap that the filter lifts needs no page two, and pages
  would put the group a person wants behind a count they cannot
  guess.
- A scroller on the popover. It would fix the overflow and leave the
  reading problem, and the filter is the answer to that.
- Anything server-side: no limit on `Store#all_groups`, no second
  read, no query. The dialog already has the list.
- The group list at `/groups` (`Admin::GroupsIndex`), which is a page
  and scrolls like one.
