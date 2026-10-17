# Each card's search key: its values folded the way the search compares
# them, worked out when the card is written so that a search reads
# these rows rather than building every contact to read them off
# (docs/plans/2026-10-17-search-keys.md). Derived from the stored card
# like card_properties, so Store#rebuild_index makes it again and a
# card's delete cascades it away.
#
# Filled here through Admin::Search.key, the app's own rule, rather
# than a copy spelled out against VCard the way 012 is: this is index,
# not data, so what it must agree with is the search reading it today,
# and a later change to what is keyed re-derives it the same way.
#
# `text: true` on every column because this is a STRICT table, which
# refuses Sequel's plain String.
require "pro_tacts/admin/search"
require "pro_tacts/contact"
require "pro_tacts/vcard"

Sequel.migration do
  up do
    create_table(:search_keys, strict: true) do
      foreign_key :card_id, :cards, type: String, text: true, primary_key: true, null: false, on_delete: :cascade
      String :text, text: true, null: false
      String :phones, text: true, null: false
      String :names, text: true, null: false
    end

    self[:cards].order(:id).each do |row|
      id = row.fetch(:id)
      contact = ProTacts::Contact.new(id:, stored: ProTacts::VCard.new(row.fetch(:vcard)), birthday: nil, inherited: [])
      self[:search_keys].insert(card_id: id, **ProTacts::Admin::Search.key(contact).to_h)
    end
  end

  down do
    drop_table(:search_keys)
  end
end
