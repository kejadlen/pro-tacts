# Groups: shared attributes composed into their members' cards at read
# (docs/plans/2026-08-24-vcard-storage-and-groups.md). A group is
# server-side state — membership is never exposed to the client — and
# the properties it holds are verbatim content lines rather than parsed
# structure, for the same reason the cards are stored as bytes: what
# the group's author wrote is what a member's card carries, and a
# property this server does not model rides through composition
# untouched (RFC 6352 section 6.3.2.2).
#
# No timestamps on these tables, the birthdays' own reason: the rows
# are current state, replaced wholesale by whatever authoring last
# wrote them, and the change log — whose fan-out entries carry the
# 'group' action below — is the history of a group's edits.
#
# `text: true` on every string column because these are STRICT tables,
# which refuse Sequel's plain String. A local rather than a constant,
# for the reason 001 records.
now = "(strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"

Sequel.migration do
  change do
    # A group's own row: an id and the name the admin surfaces show.
    # The name is for the author; a member's card never carries it.
    create_table(:groups, strict: true) do
      String :id, text: true, primary_key: true, null: false
      String :name, text: true, null: false
    end

    # What a group contributes, as the content lines to compose into a
    # member's card. `position` is the line's place in the group, which
    # fixes the order the composition serves them in.
    create_table(:group_properties, strict: true) do
      foreign_key :group_id, :groups, type: String, text: true, null: false, on_delete: :cascade
      Integer :position, null: false
      String :line, text: true, null: false
      primary_key [:group_id, :position]
    end

    # Membership. Deleting a card drops the membership — the group
    # outlives the member — and deleting a group drops everything it
    # had, members included.
    create_table(:group_members, strict: true) do
      foreign_key :group_id, :groups, type: String, text: true, null: false, on_delete: :cascade
      foreign_key :card_id, :cards, type: String, text: true, null: false, on_delete: :cascade
      primary_key [:group_id, :card_id]
    end

    # The change log's action grows its fourth value: group, the
    # fan-out entry a group edit writes for each member whose served
    # card the edit moved. Nothing writes it yet — that is the write
    # half's task — but the constraint widens here, with the tables the
    # action will name, because a schema and the actions it admits are
    # one decision. The rebuild is 003's own move: SQLite cannot alter
    # a CHECK constraint, so the table is created again beside the old
    # one, rows copied with their sequences (every client's sync token
    # state, copied rather than regenerated so no token skips a
    # change), old dropped, new renamed. Nothing references this table,
    # so the drop takes nothing with it.
    create_table(:changes_new, strict: true) do
      primary_key :sequence, type: Integer
      String :card_id, text: true, null: false
      String :action, text: true, null: false
      String :etag, text: true
      String :created_at, text: true, null: false, default: Sequel.lit(now)
      constraint(:action_is_known, action: %w[put delete edit group])
    end

    run "INSERT INTO changes_new (sequence, card_id, action, etag, created_at) " \
        "SELECT sequence, card_id, action, etag, created_at FROM changes"
    drop_table(:changes)
    rename_table(:changes_new, :changes)
  end
end
