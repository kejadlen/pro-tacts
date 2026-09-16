# A picker beside the birthday, not instead of it

2026-09-15. The birthday row grows a calendar affordance. The three
controls docs/plans/2026-09-07-web-birthday-editor.md put there stay
exactly as they were; this adds a fourth thing to the row and changes
nothing about what posts.

## Why the picker cannot be the row

`<input type="date">` holds one shape: a complete year, month, and
day. The model holds six (RFC 6350 section 4.3.1, and `Birthday`'s
constructor), and the birthday editor is deliberately the one screen
where all six are reachable — the plan above argues that at length.
Swapping the three controls for a date input would take four of those
six off the screen, and a contact already holding one could not be
opened for editing without losing it.

So the date input is not a field. It is an affordance that writes the
fields: the person clicks a calendar, picks a day, and the month,
day, and year boxes fill in. They remain what the form submits, the
save is untouched, and the no-year birthday is still typed the way it
always was — pick the date, clear the year.

That last step is the trade this control makes and it is not hidden:
a calendar cannot express "December 10, no year," so picking always
writes three values and one of them may need deleting. The row's
own boxes are the shorter path for that case, and they are still
right there.

## How it opens

The button calls `showPicker()` on a date input the row keeps but
never shows. There is no calendar drawn here — no month grid, no
Alpine component, no third-party widget. The browser's own picker is
better at this than anything this app would build, and it carries its
keyboard handling and its localization with it.

The input is hidden by being taken out of flow at zero width
(admin.css), not by `display: none`. `showPicker()` throws
`InvalidStateError` on an element that is not mutable, and what the
standard promises about an element that is not rendered at all is not
something worth resting on — so the input stays rendered and simply
occupies no space. It carries no `name`, so nothing of it reaches the
save, and `tabindex="-1"` with `aria-hidden` keeps it out of both the
tab order and the accessibility tree: the button is the control a
person meets.

Opening syncs the input from the three boxes rather than prefilling
it once at render, so a date typed into the boxes is where the
calendar opens. A partial birthday assembles a string no date input
accepts, and the value sanitization algorithm for the date state
(HTML section 4.10.5.1.7) leaves the input empty rather than
erroring — which is the behavior wanted, and why no guard stands
there.

## The row now holds two buttons

The picker and the remove control are both `.icon-button`s in the
`.date-row`, and the narrow shapes stack them in the column the
single button used to have to itself. They are told apart by order
rather than by a class or a data attribute: the picker renders in
both the standing row and the one the add dialog reveals, the remove
only in the standing row, so the picker is the first button either
way and the remove, where it exists, is the second. Only the second
takes the danger color on hover — the picker is not destructive and
keeps the quiet register.

Two selectors in admin.css shed a bare `input` for
`input[type="number"]` along the way, and both were latent bugs
waiting for a second kind of input in this row: `:last-of-type`
counts by tag and would have named the date input instead of the
year box, and the strike-through rule's `:not(:has(input:not(
:placeholder-shown)))` would have read the row as filled forever,
a date input supporting no placeholder and so never matching
`:placeholder-shown`.

## Non-goals

- A calendar this app draws. The native picker is the whole point.
- Reaching the four unserved shapes through the picker. They are
  typed, as they always were.
- Any change to what posts, what the save parses, or what a client
  receives. This is one button.
