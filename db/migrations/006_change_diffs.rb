# The change log grows a diff: the lines each write added and removed,
# as the JSON object ProTacts::CardDiff spells. The etag says a card
# changed and the diff says how — and like the etag, it is a fact about
# a card that has since moved on, so nothing can derive it later. The
# card as served, not the bytes stored, for the etag's own reason: the
# two describe one write, and a client's download is what both are
# about.
#
# The old rows are dropped rather than copied across, which every
# migration before this one refused to do. An entry written before this
# column has no diff and no way to be given one, so carrying it would
# mean a nullable column whose whole point is that it is never null —
# and this address book has never run anywhere but a development
# machine, so the history discarded is a seeded database's.
#
# What that costs, if this is ever untrue: the sequence starts at 1
# again, so a client holding a token from the old log sits past the end
# of the new one and hears about nothing until the log grows past its
# number, and Store#ctag — the sequence itself — moves backwards, which
# a client is entitled to read as no change at all. Both are resolved
# by removing the account and adding it again. A later column on this
# table is an ALTER TABLE ADD COLUMN or a rebuild that copies, never
# this.
#
# `text: true` on the string columns because these are STRICT tables,
# which refuse Sequel's plain String. A local rather than a constant,
# for the reason 001 records.
now = "(strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"

Sequel.migration do
  change do
    drop_table(:changes)

    create_table(:changes, strict: true) do
      primary_key :sequence, type: Integer
      String :card_id, text: true, null: false
      String :action, text: true, null: false
      String :etag, text: true
      String :diff, text: true, null: false
      String :created_at, text: true, null: false, default: Sequel.lit(now)
      constraint(:action_is_known, action: %w[put delete edit group])
    end
  end
end
