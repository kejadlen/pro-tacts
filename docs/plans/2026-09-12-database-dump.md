# The database dump

2026-09-12. `rake db:dump` writes what the store cannot rebuild as
plain files, into `data/dump` unless `DUMP` names another directory.
It replaces the git export
after every write that `2026-08-24-vcard-storage-and-groups.md`
describes: the app runs no git, and history is whatever the directory's
owner keeps of it.

## What it holds

That plan predates birthdays and groups living beside the card, so "the
stored card" is no longer everything about a contact. The dump holds
all three, split the way the store splits them:

| Path | Holds |
|---|---|
| `cards/<id>.vcf` | The stored card, byte for byte |
| `birthdays.yml` | Every birthday, keyed by card id, in any of the six shapes |
| `groups/<id>.yml` | A group's name, the lines it lends, and its members |

The change log and the index are left out. The index is rebuilt from the
cards, and the change log is sync history that no restore would replay.
Nothing reads a dump back; a restore would need an importer.

## A dump over a dump

`cards/` and `groups/` are made to hold exactly what the store holds, so
a card or group deleted from the store is deleted from the directory.
Anything else in the directory, such as a repository's own files, is left
alone, and unchanged files are not rewritten.

The parts are read in one transaction (`Store#snapshot`), deferred so the
read takes no write lock and a running server's writes are not held up.
