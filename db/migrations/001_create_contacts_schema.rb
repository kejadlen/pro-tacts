# The whole schema, in one migration: this is the first one, and every
# table in it arrived together.
#
# `text: true` on every string column because these are STRICT tables,
# which admit only SQLite's own type names, and Sequel's plain String is
# a varchar.
#
# Timestamps are UTC ISO 8601 to the millisecond, written by SQLite
# rather than by Ruby so that one clock stamps every row. There is no
# ON UPDATE in SQLite, so a column default covers the insert and
# Store#put sets updated_at itself on the way through.
# A local rather than a constant: a migration is loaded into the top
# level, and the next one would collide with it.
now = "(strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))"

Sequel.migration do
  change do
    # The card as submitted, and nothing derived from it. No etag column:
    # an etag is a hash of the card served, which is this row, so storing
    # one would be a second copy of a fact already here and a second copy
    # that could drift. Contact computes it. The change log's etag is a
    # different thing and does need storing, see below.
    create_table(:cards, strict: true) do
      String :id, text: true, primary_key: true, null: false
      String :vcard, text: true, null: false
      String :created_at, text: true, null: false, default: Sequel.lit(now)
      String :updated_at, text: true, null: false, default: Sequel.lit(now)
    end

    # Sync history, and the one table with nothing behind it. A card id
    # rather than a foreign key, because a tombstone has to outlive the
    # card it is about. `primary_key` gives an AUTOINCREMENT rather than
    # a bare rowid, because a sequence number reused after a delete would
    # let a client holding an older token skip a change it never saw.
    #
    # The etag here is the one thing in the schema that is a hash and
    # still has to be stored: it is what the card hashed to at that
    # write, and the card has moved on since, so nothing can recompute
    # it.
    create_table(:changes, strict: true) do
      primary_key :sequence, type: Integer
      String :card_id, text: true, null: false
      String :action, text: true, null: false
      String :etag, text: true
      String :created_at, text: true, null: false, default: Sequel.lit(now)
      constraint(:action_is_known, action: %w[put delete])
    end

    # Derived from the cards from here down: a projection, not a copy,
    # and safe to drop. `position` is the property's place in the card,
    # which is the only identity a repeated property has. Names are
    # compared without case because `FN` and `fn` are one name (RFC 6350
    # section 3.3, which RFC 2426 leaves unsaid), and parameter values
    # because Contacts uppercases them on every card it touches (see
    # docs/plans/2026-08-24-corrections-from-the-first-write.md).
    # No timestamps from here down. These rows are replaced wholesale
    # every time a card is indexed, so a created_at on one would record
    # when the projection last ran and imply a history the property does
    # not have.
    create_table(:card_properties, strict: true) do
      foreign_key :card_id, :cards, type: String, text: true, null: false, on_delete: :cascade
      Integer :position, null: false
      String :property_group, text: true
      String :name, text: true, null: false, collate: "NOCASE"
      String :value, text: true, null: false
      primary_key [:card_id, :position]
      index [:name, :value]
    end

    create_table(:card_parameters, strict: true) do
      String :card_id, text: true, null: false
      Integer :position, null: false
      String :name, text: true, null: false, collate: "NOCASE"
      String :value, text: true, null: false, collate: "NOCASE"
      foreign_key [:card_id, :position], :card_properties, on_delete: :cascade
      index [:name, :value]
    end
  end
end
