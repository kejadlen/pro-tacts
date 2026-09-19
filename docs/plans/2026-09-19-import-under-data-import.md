# Import collateral under data/import

2026-09-19. The import tasks' whole world moved under `data/import`,
and the last step of an import stopped being named for its action.

## The layout

```
data/import/
├── config.yml   # standing data between plans (ProTacts::Import::Config)
├── active/      # the plans in flight
└── done/        # plans filed away, every contact off this Mac
```

The config's first key is `host`: the base URL `import:execute`
lands on, and the only place a host is named — command line included —
so a plan cannot be aimed at another server by accident. Config
parses it: a bare hostname is read as HTTPS, and anything but an http
or https URL is refused at the read. Finalize takes no host at all,
reading the one its plan recorded.

Before, plans lived in `data/imports` beside nothing. Everything the
tasks keep now sits under the one directory, plans in flight under
`active/` and finished under `done/` — the two states a plan's
directory names. A machine with plans in the old place moves them
once by hand:

```bash
mkdir -p data/import/active data/import/done
mv data/imports/* data/import/active/
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
status read sweeps any a dead run left in `active/` before listing —
so its in-flight list is what still has work, and the finished plans
appear under a `done:` section below, kept with their cards and
sources for as long as `data/` is.
