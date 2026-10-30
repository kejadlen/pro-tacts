# Entities, and every card one of them: the first step toward the
# shape docs/plans/2026-10-24-cards-and-groups-as-entities.md weighed,
# taken for the cards alone. An entity is an id and nothing else; a
# card is the component an entity carries when it is a contact, keyed
# by the entity's id and gone when the entity is.
#
# No kind column. What an entity is follows from the components it
# carries, so a kind would be a second record of a fact the tables
# already hold.
#
# The entity's id is its own, not the card's. A card's id is its href,
# which a client chooses (a UUID, as often as not) and Store#reid
# moves; an entity's is minted, in ChangeId's alphabet at one length
# for every kind, and the CHECK below holds it there. The href stays
# on the card, unique, and is still what every table under the card
# names, so nothing that reads a card by its href changes. A card
# whose href is already a minted id keeps it as its entity's id too,
# which costs nothing and changes nothing a person reads; any other
# is given a fresh one.
#
# cards gains its new key, which SQLite cannot add to a table that
# exists, so it is rebuilt — and with it every table that references
# it, for the reason 005 records: dropping the old cards runs an
# implicit DELETE FROM, and the birthdays, the memberships, and the
# index would cascade away behind it. Renaming cards aside first does
# not dodge that: with foreign keys on, a rename rewrites the
# children's references to follow it, legacy_alter_table or not. So
# every table is created beside its old one, rows copied, the children
# dropped before the parent, and renamed into place. The indexes are
# named outright and made last, because their old namesakes hold the
# names until the old tables go.
#
# `text: true` and locals over constants, for the reasons 001 and 004
# record. The length is written out rather than read from ChangeId: a
# migration states the schema it made, whatever the code says later.
require "pro_tacts/change_id"

now = "(strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"
length = 12

Sequel.migration do
  change do
    create_table(:entities, strict: true) do
      String :id, text: true, primary_key: true, null: false
      constraint(:id_is_a_change_id, Sequel.function(:glob, "[k-z]" * length, :id))
    end

    create_table(:cards_new, strict: true) do
      foreign_key :entity_id, :entities, type: String, text: true, primary_key: true, null: false,
                                         on_delete: :cascade
      String :id, text: true, null: false, unique: true
      String :vcard, text: true, null: false
      String :created_at, text: true, null: false, default: Sequel.lit(now)
      String :updated_at, text: true, null: false, default: Sequel.lit(now)
    end

    create_table(:card_properties_new, strict: true) do
      foreign_key :card_id, :cards_new, key: :id, type: String, text: true, null: false, on_delete: :cascade
      Integer :position, null: false
      String :property_group, text: true
      String :name, text: true, null: false, collate: "NOCASE"
      String :value, text: true, null: false
      primary_key [:card_id, :position]
    end

    create_table(:card_parameters_new, strict: true) do
      String :card_id, text: true, null: false
      Integer :position, null: false
      String :name, text: true, null: false, collate: "NOCASE"
      String :value, text: true, null: false, collate: "NOCASE"
      foreign_key [:card_id, :position], :card_properties_new, on_delete: :cascade
    end

    create_table(:birthdays_new, strict: true) do
      foreign_key :card_id, :cards_new, key: :id, type: String, text: true, null: false, primary_key: true,
                                        on_delete: :cascade
      Integer :year
      Integer :month
      Integer :day
    end

    create_table(:group_members_new, strict: true) do
      foreign_key :group_id, :groups, type: String, text: true, null: false, on_delete: :cascade
      foreign_key :card_id, :cards_new, key: :id, type: String, text: true, null: false, on_delete: :cascade
      primary_key [:group_id, :card_id]
    end

    create_table(:search_keys_new, strict: true) do
      foreign_key :card_id, :cards_new, key: :id, type: String, text: true, primary_key: true, null: false,
                                        on_delete: :cascade
      String :key, text: true, null: false
    end

    create_table(:sort_keys_new, strict: true) do
      foreign_key :card_id, :cards_new, key: :id, type: String, text: true, primary_key: true, null: false,
                                        on_delete: :cascade
      String :sort_key, text: true, null: false
    end

    # Minted hrefs first, so a fresh draw that collides with one raises
    # on the primary key rather than taking an id a later card keeps.
    rows = self[:cards].order(:id).all.partition { ProTacts::ChangeId.minted?(it.fetch(:id)) }.flatten
    rows.each do |row|
      id = ProTacts::ChangeId.minted?(row.fetch(:id)) ? row.fetch(:id) : ProTacts::ChangeId.mint(length)
      self[:entities].insert(id:)
      self[:cards_new].insert(row.merge(entity_id: id))
    end
    run "INSERT INTO card_properties_new (card_id, position, property_group, name, value) " \
        "SELECT card_id, position, property_group, name, value FROM card_properties"
    run "INSERT INTO card_parameters_new (card_id, position, name, value) " \
        "SELECT card_id, position, name, value FROM card_parameters"
    run "INSERT INTO birthdays_new (card_id, year, month, day) " \
        "SELECT card_id, year, month, day FROM birthdays"
    run "INSERT INTO group_members_new (group_id, card_id) SELECT group_id, card_id FROM group_members"
    run "INSERT INTO search_keys_new (card_id, key) SELECT card_id, key FROM search_keys"
    run "INSERT INTO sort_keys_new (card_id, sort_key) SELECT card_id, sort_key FROM sort_keys"

    drop_table(:card_parameters)
    drop_table(:card_properties)
    drop_table(:birthdays)
    drop_table(:group_members)
    drop_table(:search_keys)
    drop_table(:sort_keys)
    drop_table(:cards)

    rename_table(:cards_new, :cards)
    rename_table(:card_properties_new, :card_properties)
    rename_table(:card_parameters_new, :card_parameters)
    rename_table(:birthdays_new, :birthdays)
    rename_table(:group_members_new, :group_members)
    rename_table(:search_keys_new, :search_keys)
    rename_table(:sort_keys_new, :sort_keys)

    add_index(:card_properties, [:name, :value], name: :card_properties_name_value_index)
    add_index(:card_parameters, [:name, :value], name: :card_parameters_name_value_index)
    add_index(:sort_keys, [:sort_key, :card_id], name: :sort_keys_sort_key_card_id_index)
  end
end
