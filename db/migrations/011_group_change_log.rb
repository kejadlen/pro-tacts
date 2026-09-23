# A change log for groups, the cards' own (001) beside it: one entry
# per store primitive that moves a group, its own sequence and
# nothing synced from it — the cards' sequence is the ctag and the
# sync token's state, and a group write changes no card's bytes that
# the fan-out has not already logged (docs/plans/2026-09-23-group-
# change-log.md, "Why its own table").
#
# `detail` is a JSON object shaped by its action — the name a create
# or rename left, the moved lines a `lines` write carried in
# CardDiff's spelling, the card a join or leave moved, and a delete's
# tombstone: the whole group, which the entry is thereafter the only
# record of. One value rather than a table of facts, CardDiff's own
# reason: displayed beside its entry, never queried.
#
# `group_id` is an id and not a foreign key, the card log's own
# reason: a tombstone has to outlive the group it is about.
# AUTOINCREMENT for that reason too: the sequence is the log's order,
# and a number reused after a delete would misorder the history.
#
# `text: true` on the string columns because these are STRICT tables,
# which refuse Sequel's plain String. A local rather than a constant,
# for the reason 001 records.
now = "(strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"

Sequel.migration do
  change do
    create_table(:group_changes, strict: true) do
      primary_key :sequence, type: Integer
      String :group_id, text: true, null: false
      String :action, text: true, null: false
      String :detail, text: true, null: false
      String :created_at, text: true, null: false, default: Sequel.lit(now)
      constraint(:action_is_known, action: %w[create rename lines join leave delete])
    end
  end
end
