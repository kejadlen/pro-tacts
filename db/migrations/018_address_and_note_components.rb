# The addresses and notes leave the bytes and become components of the
# entities (docs/plans/2026-10-25-contacts-on-entities.md, "The
# model"): an address — ADR's seven components and the one label a
# reader shows — at a position on its entity, and a note, at most one,
# on its entity. Every ADR and NOTE moves off each card's stored bytes
# onto the card's entity, and off the group lines onto the group's
# entity, and the table that held the group's lines goes — a group
# lends nothing as a line anymore, so what it lends needs no line
# shape to be held in.
#
# A card's ADRs and NOTE are read through Contact's own walks
# (take_addresses, take_note), so the move is the same reading every
# arrival takes from that day on: the label of an address is
# Contact.label_of's reading of it, and a line that would not read
# stays in the card's bytes, the parser's own posture. The X-ABLabel
# paired to an ADR goes with it; one pairing with a phone's group
# stays.
#
# The index rows hold positions into the card's lines, and taking
# lines out moves the positions behind them, so each card whose bytes
# moved has its card_properties and card_parameters rows written again
# from the card as it now stands — reindex's own walk, spelled out
# here because the migration cannot call it. The search keys keep what
# they hold: a key's address and note texts are the same texts read
# from the components, so there is nothing to recompute.
#
# The stored bytes no longer compose to what a client downloads for
# any card with an address or a note — served is stored plus
# components from here on — so every such card's etag moves with this
# migration, and a client refetches on its next sync. No change-log
# entry is written, 002's own bargain.
#
# `text: true` and the length not read from the code, for the reasons
# 001 and 016 record.
require "pro_tacts/contact"
require "pro_tacts/vcard"

Sequel.migration do
  up do
    create_table(:addresses, strict: true) do
      foreign_key :entity_id, :entities, type: String, text: true, null: false, on_delete: :cascade
      Integer :position, null: false
      String :po_box, text: true, null: false
      String :extended, text: true, null: false
      String :street, text: true, null: false
      String :locality, text: true, null: false
      String :region, text: true, null: false
      String :postal_code, text: true, null: false
      String :country, text: true, null: false
      String :label, text: true
      primary_key [:entity_id, :position]
    end

    create_table(:notes, strict: true) do
      foreign_key :entity_id, :entities, type: String, text: true, primary_key: true, null: false,
                                        on_delete: :cascade
      String :text, text: true, null: false
    end

    self[:cards].order(:id).each do |row|
      id = row.fetch(:id)
      card = ProTacts::VCard.new(row.fetch(:vcard))
      addresses, stored = ProTacts::Contact.take_addresses(card)
      note, stored = ProTacts::Contact.take_note(stored)
      entity_id = row.fetch(:entity_id)
      addresses.each.with_index do |address, position|
        self[:addresses].insert(
          entity_id:,
          position:,
          po_box: address.po_box,
          extended: address.extended,
          street: address.street,
          locality: address.locality,
          region: address.region,
          postal_code: address.postal_code,
          country: address.country,
          label: address.label,
        )
      end
      self[:notes].insert(entity_id:, text: note) if note

      next if stored.to_s == card.to_s

      self[:cards].where(id:).update(vcard: stored.to_s)
      self[:card_properties].where(card_id: id).delete
      stored.properties.each.with_index do |property, position|
        self[:card_properties].insert(
          card_id: id,
          position:,
          property_group: property.group,
          name: property.name,
          value: property.value,
        )
        property.parameters.each do |name, value|
          self[:card_parameters].insert(card_id: id, position:, name:, value:)
        end
      end
    end

    self[:groups].order(:id).each do |row|
      id = row.fetch(:id)
      lines = self[:group_properties].where(group_id: id).order(:position).select_map(:line)
      next if lines.empty?

      card = ProTacts::VCard.new(lines.map { "#{it}\r\n" }.join)
      addresses, = ProTacts::Contact.take_addresses(card)
      note, = ProTacts::Contact.take_note(card)
      addresses.each.with_index do |address, position|
        self[:addresses].insert(
          entity_id: id,
          position:,
          po_box: address.po_box,
          extended: address.extended,
          street: address.street,
          locality: address.locality,
          region: address.region,
          postal_code: address.postal_code,
          country: address.country,
          label: address.label,
        )
      end
      self[:notes].insert(entity_id: id, text: note) if note
    end
    drop_table(:group_properties)
  end
end
