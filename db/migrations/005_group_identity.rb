# Group identity: a name a group may not have, and an id in the shape
# jj spells a change id.
#
# The name is the author's label, and 004 made it required — which left
# the empty string in as a second spelling of nameless, one that reads
# on a member's page as an empty badge. Nullable is the honest column:
# NULL is a group with no name, '' is refused, and a nameless group is
# displayed by its id instead (Store#inherited_rows composes the
# fallback into the read).
#
# Which makes the id something a person reads, so it is minted rather
# than chosen: four reverse-hex letters, k through z, the alphabet jj
# renders a change id in so that an id can never be mistaken for a hash
# (Store#next_group_id). GLOB rather than LIKE, because GLOB takes the
# character ranges this shape is written as and because its case
# sensitivity is its own rather than a per-connection pragma's — 004
# records the second reason at length. `glob(X, Y)` is `Y GLOB X`:
# pattern first, SQLite's argument order for the function form.
#
# Both are CHECK constraints, and SQLite cannot alter one, so the table
# is rebuilt the way 003 and 004 rebuilt changes. Unlike changes,
# groups is referenced: with foreign keys on, DROP TABLE runs an
# implicit DELETE FROM first, and the members and the properties would
# cascade away behind it. So all three tables are rebuilt together —
# created beside the old ones, rows copied, the children dropped before
# the parent, then renamed into place, which is also what points the
# children's foreign keys back at `groups`. Turning foreign keys off
# around a single-table rebuild is not available here: that pragma is a
# no-op inside a transaction, and a migration is one.
#
# A row whose id is not four letters in k-z stops the migration rather
# than being rewritten into something that fits. Nothing public writes
# these tables, so such a row was seeded by hand, and choosing its new
# id is the author's call and not this file's.
#
# The shareable-line constraint is restated rather than referenced —
# a migration is standalone, and 004 holds the reasoning for which
# names it admits. `text: true` and locals over constants, for the
# reasons 001 and 004 record.
folded = Sequel.function(:upper, :line)
shareable = %w[ADR NOTE].flat_map { |name|
  [Sequel.like(folded, "#{name}:%"), Sequel.like(folded, "#{name};%")]
}

Sequel.migration do
  change do
    create_table(:groups_new, strict: true) do
      String :id, text: true, primary_key: true, null: false
      String :name, text: true
      constraint(:id_is_a_change_id, Sequel.function(:glob, "[k-z][k-z][k-z][k-z]", :id))
      constraint(:name_is_absent_or_given, Sequel.|({name: nil}, Sequel.~(name: "")))
    end

    create_table(:group_properties_new, strict: true) do
      foreign_key :group_id, :groups_new, type: String, text: true, null: false, on_delete: :cascade
      Integer :position, null: false
      String :line, text: true, null: false
      primary_key [:group_id, :position]
      constraint(:line_is_shareable, Sequel.|(*shareable))
    end

    create_table(:group_members_new, strict: true) do
      foreign_key :group_id, :groups_new, type: String, text: true, null: false, on_delete: :cascade
      foreign_key :card_id, :cards, type: String, text: true, null: false, on_delete: :cascade
      primary_key [:group_id, :card_id]
    end

    run "INSERT INTO groups_new (id, name) SELECT id, name FROM groups"
    run "INSERT INTO group_properties_new (group_id, position, line) " \
        "SELECT group_id, position, line FROM group_properties"
    run "INSERT INTO group_members_new (group_id, card_id) " \
        "SELECT group_id, card_id FROM group_members"

    drop_table(:group_properties)
    drop_table(:group_members)
    drop_table(:groups)

    rename_table(:groups_new, :groups)
    rename_table(:group_properties_new, :group_properties)
    rename_table(:group_members_new, :group_members)
  end
end
