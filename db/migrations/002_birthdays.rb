# Birthdays leave the cards and become state of their own: a partial
# date has no vCard 3.0 spelling (RFC 2425 section 5.8.4 requires all
# three components), so the card stops carrying BDAY and the database
# holds it — docs/plans/2026-08-31-partial-birthdays.md.
#
# `text: true` on the string column because these are STRICT tables,
# which refuse Sequel's plain String. No timestamp: a birthday changes
# with its card's write and the card's stamp is the write's stamp.
require "pro_tacts/birthday"
require "pro_tacts/vcard"

Sequel.migration do
  change do
    # One birthday per card, keyed by it and dying with it. The columns
    # are nullable integers whose nulls carry the shape, validated by
    # Birthday rather than by the table: the six legal shapes are a
    # grammar fact, not a constraint SQLite can check.
    #
    # This is the third table in the database that cannot be rebuilt.
    # The cards and the change log were the first two; the index tables
    # remain projections that `rake index:rebuild` will make again. A
    # birthday cannot be re-derived from its card because it no longer
    # lives there.
    create_table(:birthdays, strict: true) do
      foreign_key :card_id, :cards, type: String, text: true, null: false, primary_key: true, on_delete: :cascade
      Integer :year
      Integer :month
      Integer :day
    end

    # The same move a write makes, run over the cards already stored: a
    # BDAY in a modeled spelling moves into the new table and out of the
    # card, and any other BDAY stays in the card verbatim. Composed
    # again on read, a modeled birthday changes served bytes only by
    # position — it lands before END:VCARD — so clients refetch each
    # birthday-carrying card once, by design rather than by accident.
    # The change log is not written: as far as any client can tell, no
    # contact changed, and the stamps are left alone to say the same.
    # Spelled out against VCard and Birthday directly rather than
    # through a Store helper, so what this migration does cannot drift
    # with the app's internals; its test pins the behavior.
    self[:cards].order(:id).each do |row|
      # The same move a write makes, one arm per shape the stored
      # card's BDAY lines take — only the modeled single line moves.
      case ProTacts::VCard.new(row.fetch(:vcard)).partition { it.names?("BDAY") }
      in [[line], others]
        property = line.property
        birthday = property && ProTacts::Birthday.from_property(property)
        next if birthday.nil?

        self[:cards].where(id: row.fetch(:id)).update(vcard: others.map(&:verbatim).join)
        self[:birthdays].insert(
          card_id: row.fetch(:id),
          year: birthday.year,
          month: birthday.month,
          day: birthday.day,
        )
      in [[], _] | [_, _]
        # Nothing to move, or lines the model cannot recompose: the
        # card stands as stored.
      end
    end
  end
end
