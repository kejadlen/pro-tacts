# The one-note invariant lands: a contact carries at most one NOTE,
# stored and served, and what a group lends composes into it as a
# section rather than a second line — because macOS keeps only the
# last of two NOTE lines and a PUT stores the truncation
# (docs/plans/2026-09-25-one-note-per-contact.md, which this migration
# makes true of the data the day it lands).
#
# What is already stored with several joins into one: the texts with a
# blank line between, which is the shape the write path joins foreign
# input into and the shape the sections read beside. No change-log
# entry is written, 002's own bargain: the stamps are left to say the
# same, and a client that does not refetch keeps its card until the
# next change — a PUT of which #subtract_notes reads as the
# truncation it is rather than a mangle.
#
# Spelled out against VCard directly rather than through a Store
# helper, so what this migration does cannot drift with the app's
# internals; its test pins the behavior.
require "pro_tacts/vcard"

Sequel.migration do
  change do
    self[:cards].order(:id).each do |row|
      card = ProTacts::VCard.new(row.fetch(:vcard))
      notes = card.lines.select { it.names?("NOTE") }
      next unless notes.length > 1

      texts = notes.map { it.property&.text || it.verbatim.chomp }
      joined = card.replace("NOTE", ["NOTE:#{ProTacts::VCard.escape(texts.join("\n\n"))}\r\n"])
      self[:cards].where(id: row.fetch(:id)).update(vcard: joined.to_s)
    end

    self[:group_properties].select(:group_id).distinct.each do |row|
      gid = row.fetch(:group_id)
      rows = self[:group_properties].where(group_id: gid).order(:position).all
      notes = rows.select { it.fetch(:line)[/\A[^;:]*/].to_s.casecmp?("NOTE") == true }
      next unless notes.length > 1

      # The joined line keeps the earliest position — the position the
      # composition lent in, and the one a propagated edit writes back
      # to — and the rest of the rows go.
      texts = notes.map {
        ProTacts::VCard.new(it.fetch(:line)).lines.fetch(0).property&.text || it.fetch(:line)
      }
      keep = notes.fetch(0).fetch(:position)
      self[:group_properties]
        .where(group_id: gid, position: notes.drop(1).map { it.fetch(:position) }).delete
      self[:group_properties].where(group_id: gid, position: keep)
        .update(line: "NOTE:#{ProTacts::VCard.escape(texts.join("\n\n"))}")
    end
  end
end
