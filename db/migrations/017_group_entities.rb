# Every group an entity, as 016 made every card one: the group is the
# component an entity carries when it is a group, keyed by the
# entity's id and gone when the entity is.
#
# A group's id is its entity's, with nothing else to name it by, so
# each group is re-minted at 016's length and its four letters are
# retired — the shape 005 gave them is now the entities' CHECK. The
# group change log is moved with it, Store#reid's reason for moving a
# card's: the group is the same group, and its page keeps its record.
# A tombstone's id moves too, which keeps a deleted group's history
# reading under one id even though nothing will mint the old one
# again.
#
# The entities primary key keeps two entities from sharing an id, not
# one entity from carrying both a card and a group. Nothing reads such
# an entity sensibly yet, so the triggers below refuse it, for both
# components and for an insert or a move. Triggers because a foreign
# key cannot say "absent from that table", and the composite-key
# spelling needs the kind column 016 declined.
#
# The rebuild is 005's again, for its reason — groups and the three
# tables that reference it created beside the old ones, rows copied,
# children dropped before the parent, renamed into place — and the
# constraints restated rather than referenced, a migration being
# standalone; 004 and 005 hold the reasoning for each. The name index
# is made last, 016's reason.
require "pro_tacts/change_id"

folded = Sequel.function(:upper, :line)
shareable = %w[ADR NOTE].flat_map { |name|
  [Sequel.like(folded, "#{name}:%"), Sequel.like(folded, "#{name};%")]
}
length = 12

Sequel.migration do
  change do
    create_table(:groups_new, strict: true) do
      foreign_key :id, :entities, type: String, text: true, primary_key: true, null: false, on_delete: :cascade
      String :name, text: true
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
      foreign_key :card_id, :cards, key: :id, type: String, text: true, null: false, on_delete: :cascade
      primary_key [:group_id, :card_id]
    end

    create_table(:group_photos_new, strict: true) do
      foreign_key :group_id, :groups_new, type: String, text: true, primary_key: true, null: false,
                                          on_delete: :cascade
      File :bytes, null: false
    end

    # Every id the log names, the deleted groups' among them, so a
    # tombstone moves with the rest. One draw each, Store#new_entity's
    # reason: a live group's collision raises on the entities' key.
    old_ids = (self[:groups].select_map(:id) + self[:group_changes].distinct.select_map(:group_id)).uniq.sort
    renamed = old_ids.to_h { [it, ProTacts::ChangeId.mint(length)] }

    self[:groups].order(:id).each do |row|
      id = renamed.fetch(row.fetch(:id))
      self[:entities].insert(id:)
      self[:groups_new].insert(id:, name: row.fetch(:name))
    end
    self[:group_properties].each { self[:group_properties_new].insert(it.merge(group_id: renamed.fetch(it.fetch(:group_id)))) }
    self[:group_members].each { self[:group_members_new].insert(it.merge(group_id: renamed.fetch(it.fetch(:group_id)))) }
    self[:group_photos].each { self[:group_photos_new].insert(it.merge(group_id: renamed.fetch(it.fetch(:group_id)))) }
    renamed.each { |old, id| self[:group_changes].where(group_id: old).update(group_id: id) }

    drop_table(:group_properties)
    drop_table(:group_members)
    drop_table(:group_photos)
    drop_table(:groups)

    rename_table(:groups_new, :groups)
    rename_table(:group_properties_new, :group_properties)
    rename_table(:group_members_new, :group_members)
    rename_table(:group_photos_new, :group_photos)

    add_index(:groups, :name, unique: true, name: :groups_name_is_unique)

    {cards: [:entity_id, :groups, :id], groups: [:id, :cards, :entity_id]}.each do |table, (column, other, key)|
      {insert: "INSERT", update: "UPDATE OF #{column}"}.each do |name, event|
        run <<~SQL
          CREATE TRIGGER #{table}_#{name}_not_#{other} BEFORE #{event} ON #{table}
          WHEN EXISTS (SELECT 1 FROM #{other} WHERE #{key} = NEW.#{column})
          BEGIN SELECT RAISE(ABORT, 'entity already has a #{other.to_s.chomp("s")}'); END
        SQL
      end
    end
  end
end
