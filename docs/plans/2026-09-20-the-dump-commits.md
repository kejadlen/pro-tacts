# The dump commits

2026-09-20. `rake db:dump` commits what it wrote.
`2026-09-12-database-dump.md` left history as "whatever the
directory's owner keeps of it", and `rake console` was that owner: it
took the dump, then ran git over it, so a session that deleted the
wrong contact was a revert rather than a restore from backup. The git
moves into `tasks/db.rake` and the console keeps only the `db:dump`
it already invoked.

## Why it belonged to the dump

The console was the one caller that could assume git — the image
carried it for that task and nothing else. Now that git is in the
image outright, the assumption is the dump's to make, and the dump is
where it fits: the console commits because a prompt is dangerous, but
a snapshot nothing can revert to is a worse dump whatever took it.
Every other caller — a cron, a hand-run `rake db:dump` before an
upgrade, `DUMP=path` to a scratch directory — got an overwrite of the
last snapshot and no way back to it, which was never a considered
decision, only where the code sat.

So there is no flag to dump without committing. A dump the repository
does not record is the thing this replaces, and `data/dump` is
ignored by the code's repository, so the dump's own is the only place
that history can live.

## What a commit says

`dump <ISO 8601 UTC>`, and nothing else. The time is all a snapshot
has to say for itself: what moved is the change log, which the dump
leaves out on purpose (`2026-09-12-database-dump.md`), and the diff
of the commit says the rest. A dump that moved nothing commits
nothing, so the history is the writes and not the runs.

The repository is initialized on the first dump, on `main`. The
identity is passed with `-c` per invocation rather than read from the
machine's configuration, so a host that dumps needs no git identity
set up and a deployment's commits do not borrow a person's name.

## Still no git in the app

This is the tooling, not the server. The app runs no git, issues no
commit from a web request, and has no git on its write path —
`2026-08-24-vcard-storage-and-groups.md` proposed that and
`2026-09-12-database-dump.md` withdrew it. `tasks/db.rake` is the one
place in the repository that shells out to git for the dump, and a
failure there raises: a caller that was told it dumped was told it
committed.
