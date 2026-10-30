# Each card's place in a list (ContactDetails#sort_key), so a
# group's first few members by that order are a query rather than the
# whole group built and sorted to take them from — `sync:*` holds
# every card, and a contact's tag for it names five
# (docs/plans/2026-10-22-perceived-speed.md). Index, like
# search_keys: filled through the app's own sort_key, since what it
# must agree with is the order a list sorts in. A group lends no
# name, so the stored card alone decides it. The card's id stands
# behind the name for a card with neither — the store's Contact
# spelling of the fallback, written out here rather than reached for,
# a migration standing alone from the store's reads.
require "pro_tacts/contact_details"
require "pro_tacts/vcard"

Sequel.migration do
  up do
    create_table(:sort_keys, strict: true) do
      foreign_key :card_id, :cards, type: String, text: true, primary_key: true, null: false, on_delete: :cascade
      String :sort_key, text: true, null: false

      index [:sort_key, :card_id]
    end

    self[:cards].order(:id).each do |row|
      id = row.fetch(:id)
      details = ProTacts::ContactDetails.of_card(card: ProTacts::VCard.new(row.fetch(:vcard)), birthday: nil)
      sort_key = details.sort_key
      sort_key = id.downcase if sort_key.empty?
      self[:sort_keys].insert(card_id: id, sort_key:)
    end
  end

  down do
    drop_table(:sort_keys)
  end
end
