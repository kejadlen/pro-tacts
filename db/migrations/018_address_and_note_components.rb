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
# paired to an ADR goes with it, and so do the `X-` lines sharing its
# group, such as Apple's X-ABADR; one pairing with a phone's group
# stays. What the reading does not say rides on the row as JSON:
# the line's parameters less the types its label stands for, `pref`
# among them, and those companion lines, so that the move keeps them
# with the address they belong to (Contact::Address).
#
# The index rows hold positions into the card's lines, and taking
# lines out moves the positions behind them, so each card whose bytes
# moved has its card_properties and card_parameters rows written again
# from the card as it now stands — reindex's own walk, spelled out
# here because the migration cannot call it. The search keys keep what
# they hold: a key's address and note texts are the same texts read
# from the components, so there is nothing to recompute.
#
# Served is stored plus components from here on, so a card with an
# address or a note, its own or lent, serves other bytes after the
# move: the composition puts them before END:VCARD, a lent address in
# its own spelling, and a lent version marker hashes components where
# it hashed lines. The ctag is the change log's sequence and a sync
# token's delta is the log after it (Store#ctag, Store#changes), so a
# card whose served bytes moved gets an entry here, in this
# migration's transaction — without one no client hears of the move,
# and its next conditional PUT fails on the etag it kept. A card
# serving the same bytes gets none, Store#fan_out's rule.
#
# The entry is a `put`, Store#reid's action for the server rewriting a
# card, since this is neither the editor's save nor a group's write.
# Its etag is the card Contact composes from the rows written here,
# and its diff runs from the card as it served before — the
# composition the code made until this migration, spelled out below
# because no code composes that way any more — to that one, so a
# card's history still replays to the card it serves. A nameless
# group's label is its id, which 017 re-minted, so its members' diff
# names the new id where the card they were served named the old.
#
# `text: true` and the length not read from the code, for the reasons
# 001 and 016 record.
require "digest"
require "json"

require "pro_tacts/birthday"
require "pro_tacts/card_diff"
require "pro_tacts/contact"
require "pro_tacts/group"
require "pro_tacts/note_sections"
require "pro_tacts/vcard"

# The card a member served before this migration: the stored card, the
# lines each group lent it inserted (a lent NOTE as a labeled section
# of the member's one NOTE), then the birthday and one version marker
# per lending group — Contact#vcard as it stood, over `lenders`, each
# group's label and lines in group-id order. A local rather than a
# constant, for the reason 001 records.
served_before = lambda { |stored, birthday, lenders|
  lent = lenders.flat_map { |label, lines| lines.map { [label, it] } }
  notes, others = lent.partition { |_, line| line[/\A[^;:]*/].to_s.casecmp?("NOTE") }
  composed = stored.insert(others.map(&:last))
  unless notes.empty?
    sections = notes.map { |label, line|
      property = ProTacts::VCard.new(line).lines.fetch(0).property
      raise "a group lends a NOTE that will not read" if property.nil?

      ProTacts::NoteSections::Section.new(label:, text: property.text)
    }
    member = stored.property("NOTE")&.text.to_s
    composed = composed.replace("NOTE", ["NOTE:#{ProTacts::VCard.escape(ProTacts::NoteSections.join(member, sections))}"])
  end
  markers = lenders.map { |label, lines|
    version = Digest::SHA256.hexdigest([*lines, label].join("\0"))
    "X-PT-LENT:#{ProTacts::VCard.escape("#{label}:#{version}")}"
  }
  composed.insert([birthday&.to_line, *markers].compact)
}

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
      String :parameters, text: true, null: false
      String :companions, text: true, null: false
      primary_key [:entity_id, :position]
    end

    create_table(:notes, strict: true) do
      foreign_key :entity_id, :entities, type: String, text: true, primary_key: true, null: false,
                                        on_delete: :cascade
      String :text, text: true, null: false
    end

    birthdays = self[:birthdays].all.to_h {
      [it.fetch(:card_id), ProTacts::Birthday.new(year: it[:year], month: it[:month], day: it[:day])]
    }
    groups = self[:groups].order(:id).all.to_h { [it.fetch(:id), it] }
    label_of = ->(id) { groups.fetch(id).fetch(:name) || id }
    lines_by_group = self[:group_properties].order(:group_id, :position).to_hash_groups(:group_id, :line)
    lenders_before = self[:group_members].where(group_id: lines_by_group.keys).order(:card_id, :group_id)
      .to_hash_groups(:card_id, :group_id)

    # Each card's served card before the move, and its stored card and
    # components after, for the entries written once the groups have
    # moved too.
    by_card = {}
    self[:cards].order(:id).each do |row|
      id = row.fetch(:id)
      card = ProTacts::VCard.new(row.fetch(:vcard))
      addresses, stored = ProTacts::Contact.take_addresses(card)
      note, stored = ProTacts::Contact.take_note(stored)
      entity_id = row.fetch(:entity_id)
      lenders = lenders_before.fetch(id, []).map { [label_of.(it), lines_by_group.fetch(it)] }
      by_card[id] = [served_before.(card, birthdays[id], lenders), stored, addresses, note]
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
          parameters: address.parameters.to_json,
          companions: address.companions.to_json,
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

    lending = {}
    groups.each do |id, row|
      lines = lines_by_group.fetch(id, [])
      next if lines.empty?

      card = ProTacts::VCard.new(lines.map { "#{it}\r\n" }.join)
      addresses, = ProTacts::Contact.take_addresses(card)
      note, = ProTacts::Contact.take_note(card)
      unless addresses.empty? && note.nil?
        # Built for the label and the components, which are all the
        # composition reads of a lender.
        group = ProTacts::Group.new(id:, name: row.fetch(:name), label: label_of.(id), addresses:, note:, members: [])
        positioned = addresses.map.with_index { |address, position| ProTacts::Contact::LentAddress.new(position:, address:) }
        lending[id] = ProTacts::Contact::Lent.new(group:, addresses: positioned, note:)
      end
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
          parameters: address.parameters.to_json,
          companions: address.companions.to_json,
        )
      end
      self[:notes].insert(entity_id: id, text: note) if note
    end
    drop_table(:group_properties)

    lenders_after = self[:group_members].where(group_id: lending.keys).order(:card_id, :group_id)
      .to_hash_groups(:card_id, :group_id)
    by_card.each do |id, (before, stored, addresses, note)|
      lent = lenders_after.fetch(id, []).map { lending.fetch(it) }
      after = ProTacts::Contact.new(id:, stored:, birthday: birthdays[id], addresses:, note:, lent:)
      next if after.vcard.to_s == before.to_s

      self[:changes].insert(
        card_id: id,
        action: "put",
        etag: after.etag,
        diff: ProTacts::CardDiff.between(before, after.vcard).to_json,
      )
    end
  end
end
