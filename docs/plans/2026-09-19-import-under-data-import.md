# Import collateral under data/import

2026-09-19. The import tasks' whole world moved under `data/import`,
and the last step of an import stopped being named for its action.

## The layout

```
data/import/
├── config.yml   # standing data between plans (ProTacts::Import::Config)
├── plans/       # the plans in flight
└── done/        # plans filed away, every contact off this Mac
```

Before, plans lived in `data/imports` beside nothing. Everything the
tasks keep now sits under the one directory, plans active under
`plans/` and finished under `done/`. A machine with plans in the old
place moves them once by hand:

```bash
mkdir -p data/import/plans data/import/done
mv data/imports/* data/import/plans/
```

## Finalizing, not removing

The step that takes a plan's contacts off this Mac was `remove`, an
action's name, and its result was a contact `removed`. The vocabulary
now names the state: `rake import:macos:finalize` finalizes a plan's
contacts — off this Mac — and a contact's final status is `done`: on
the host, in its groups, off this Mac. `Import::Remove` is
`Import::Finalize`.

Statuses already recorded as `removed` read as `done` (`Plan` carries
the old spelling beside the new), so a plan built before the rename
still finishes and files away; nothing is rewritten on disk.

## A finished plan files away

A plan whose every contact is done is finished (`Plan#done?`). The
finalize task files one away into `done/` as its last step, and the
status read sweeps any a dead run left in `plans/` before listing —
so what status lists is what still has work, and the finished plans
are out of the way but kept, with their cards and sources, for as
long as `data/` is.
