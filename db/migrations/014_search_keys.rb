# Each card's search key (Admin::Search::Key) as JSON, so a search
# reads these rather than building every contact
# (docs/plans/2026-10-17-search-keys.md). Index, like card_properties:
# filled here through the app's own Search.key, since what it must
# agree with is the search that reads it.
require "pro_tacts/admin/search"
require "pro_tacts/contact"
require "pro_tacts/vcard"

Sequel.migration do
  up do
    create_table(:search_keys, strict: true) do
      foreign_key :card_id, :cards, type: String, text: true, primary_key: true, null: false, on_delete: :cascade
      String :key, text: true, null: false
    end

    self[:cards].order(:id).each do |row|
      id = row.fetch(:id)
      contact = ProTacts::Contact.new(id:, stored: ProTacts::VCard.new(row.fetch(:vcard)), birthday: nil, inherited: [])
      self[:search_keys].insert(card_id: id, key: ProTacts::Admin::Search.key(contact).to_json)
    end
  end

  down do
    drop_table(:search_keys)
  end
end
