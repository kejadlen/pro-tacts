# The change log's action grows a third value: edit, the admin UI's
# save (Store#rewrite). To a syncing client an edit reads the same as
# a put — the member changed, at a new etag — but the log is also the
# record of which side wrote a card, and the change-log display on the
# contact's page renders the difference.
#
# SQLite cannot alter a CHECK constraint, so the table is rebuilt:
# created again beside the old one, rows copied with their sequences,
# old dropped, new renamed. The sequence is every client's sync token
# state — copied, not regenerated, so no token skips a change; nothing
# references this table, so the drop takes nothing with it.
#
# `text: true` on the string columns because these are STRICT tables,
# which refuse Sequel's plain String. A local rather than a constant,
# for the reason 001 records.
now = "(strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"

Sequel.migration do
  change do
    create_table(:changes_new, strict: true) do
      primary_key :sequence, type: Integer
      String :card_id, text: true, null: false
      String :action, text: true, null: false
      String :etag, text: true
      String :created_at, text: true, null: false, default: Sequel.lit(now)
      constraint(:action_is_known, action: %w[put delete edit])
    end

    run "INSERT INTO changes_new (sequence, card_id, action, etag, created_at) " \
        "SELECT sequence, card_id, action, etag, created_at FROM changes"
    drop_table(:changes)
    rename_table(:changes_new, :changes)
  end
end
