# pro-tacts

A CardDAV server for my family.

## Simplifying Assumptions

- Small, trusted user group (2-3 people) — no permissions or access controls
- Network access via Tailscale — simple authentication
- Apple devices only (it might happen to work on other CardDAV clients, but
  only accidentally)

## Features

- Per-user contact ownership with contacts/groups sharing
- Groups with attributes (e.g., an address shared by all members)
- Selective sync (choose which contacts to sync rather than all-or-nothing)
- Plaintext storage in git (version history, human-readable)
