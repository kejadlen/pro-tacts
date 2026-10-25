# Every group an entity, as 016 made every card one: the group is the
# component an entity carries when it is a group, keyed by that id and
# gone when the entity is.
#
# Which puts cards and groups in one id space, and the entities
# primary key is what keeps the two apart from here on. A group whose
# id a card already holds stops the migration rather than being
# re-minted, 005's rule for a row that will not fit: a group's id is
# what a person reads, and choosing its new one is the author's call.
#
# The primary key keeps two entities from sharing an id, not one
# entity from carrying both a card and a group: a card written under a
# group's id would find the entity standing and land on it. Nothing
# reads such an entity sensibly yet, so the triggers below refuse it,
# for both components and for an insert or a move. Triggers because a
# foreign key cannot say "absent from that table", and the
# composite-key spelling needs the kind column 016 declined.
#
# The rebuild is 005's again, for its reason — groups and the three
# tables that reference it created beside the old ones, rows copied,
# children dropped before the parent, renamed into place — and the
# constraints restated rather than referenced, a migration being
# standalone; 004 and 005 hold the reasoning for each. The name index
# is made last, 016's reason.
folded = Sequel.function(:upper, :line)
shareable = %w[ADR NOTE].flat_map { |name|
  [Sequel.like(folded, "#{name}:%"), Sequel.like(folded, "#{name};%")]
}

Sequel.migration do
  change do
    taken = self[:groups].where(id: self[:cards].select(:id)).select_map(:id)
    raise "groups whose ids a card already holds: #{taken.join(", ")}" unless taken.empty?

    create_table(:groups_new, strict: true) do
      foreign_key :id, :entities, type: String, text: true, primary_key: true, null: false, on_delete: :cascade
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

    create_table(:group_photos_new, strict: true) do
      foreign_key :group_id, :groups_new, type: String, text: true, primary_key: true, null: false,
                                          on_delete: :cascade
      File :bytes, null: false
    end

    run "INSERT INTO entities (id) SELECT id FROM groups"
    run "INSERT INTO groups_new (id, name) SELECT id, name FROM groups"
    run "INSERT INTO group_properties_new (group_id, position, line) " \
        "SELECT group_id, position, line FROM group_properties"
    run "INSERT INTO group_members_new (group_id, card_id) SELECT group_id, card_id FROM group_members"
    run "INSERT INTO group_photos_new (group_id, bytes) SELECT group_id, bytes FROM group_photos"

    drop_table(:group_properties)
    drop_table(:group_members)
    drop_table(:group_photos)
    drop_table(:groups)

    rename_table(:groups_new, :groups)
    rename_table(:group_properties_new, :group_properties)
    rename_table(:group_members_new, :group_members)
    rename_table(:group_photos_new, :group_photos)

    add_index(:groups, :name, unique: true, name: :groups_name_is_unique)

    {cards: :groups, groups: :cards}.each do |table, other|
      {insert: "INSERT", update: "UPDATE OF id"}.each do |name, event|
        run <<~SQL
          CREATE TRIGGER #{table}_#{name}_not_#{other} BEFORE #{event} ON #{table}
          WHEN EXISTS (SELECT 1 FROM #{other} WHERE id = NEW.id)
          BEGIN SELECT RAISE(ABORT, 'entity already has a #{other.to_s.chomp("s")}'); END
        SQL
      end
    end
  end
end
