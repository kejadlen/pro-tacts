require "pro_tacts/import/plan"

module ProTacts
  module Import
    # Takes the originals off the Mac, once a plan has carried them to a
    # host (docs/plans/2026-09-16-importing-from-macos.md, "Removing the
    # originals"). Every check is a reason to keep a contact rather than
    # to delete one, because a wrong keep costs a second look and a wrong
    # delete costs the contact.
    class Remove
      # @rbs @plan: Plan
      # @rbs @client: _Client
      # @rbs @mac: _Mac

      class Failed < StandardError; end

      # What a run did: how many contacts it took off the Mac, and the
      # ones it left there, each named as its card names it and said why.
      # A name rather than an id, since the person reading is the one who
      # will go and look at the contact. Signed in
      # sig/pro_tacts/import.rbs, being a Data class.
      # @rbs skip
      Result = Data.define(:removed, :kept)

      #: (Plan plan, client: _Client, mac: _Mac) -> Result
      def self.call(plan, client:, mac:)
        new(plan, client:, mac:).call
      end

      #: (Plan plan, client: _Client, mac: _Mac) -> void
      def initialize(plan, client:, mac:)
        @plan = plan
        @client = client
        @mac = mac
      end

      #: () -> Result
      def call
        imported = @plan.with_status("imported")
        records = @mac.show(imported.map(&:source_id))
        gone, still_there = imported.partition { !records.key?(it.source_id) }
        # A contact this Mac no longer has is a contact removed, which is
        # what a rerun of an interrupted run sees.
        gone.each { @plan.record(it.id, "removed") }

        kept = [] #: Array[[String, String]]
        going = still_there.select { |contact|
          why = keep(contact, records.fetch(contact.source_id))
          kept << [name(contact.id), why] if why
          why.nil?
        }
        # One delete for the batch, since each one starts the script
        # again; a run that dies before the plan records them finds them
        # gone next time.
        @mac.delete(going.map(&:source_id))
        going.each { @plan.record(it.id, "removed") }

        Result.new(removed: gone.size + going.size, kept:)
      end

      private

      # Why this contact stays on the Mac, or nil for one to delete. The
      # comparison is exact because CNContact carries no modification
      # date: a contact Contacts.app rewrote on its own is kept, which is
      # the safe direction to be wrong in.
      #: (Plan::Contact contact, Hash[String, untyped] record) -> String?
      def keep(contact, record)
        backup = @plan.backup(contact.id)
        note = (backup / "note.txt").then { it.file? ? it.read : nil }
        if !on_host?(contact.id)
          "its card is no longer on #{@plan.host}"
        elsif record.fetch("vcard") != (backup / "original.vcf").read
          "it has changed on this Mac since the plan"
        elsif record.fetch("note") != note
          "its note has changed on this Mac since the plan"
        end
      end

      # The contact as its card file names it, which is what a person
      # reading this run looks for in Contacts.
      #: (String id) -> String
      def name(id)
        card = @plan.card(id)
        [card.first, card.last].reject(&:empty?).join(" ")
      end

      # Asked of the card browser rather than of `/dav/addressbook`,
      # which serves the asking user's book alone: a card in no `sync:`
      # group is on the host and outside every book, and the question
      # here is whether the host still has it at all
      # (docs/plans/2026-09-12-per-user-books.md).
      #: (String id) -> bool
      def on_host?(id)
        response = @client.call("GET", "/contacts/#{id}")
        case response.status
        when 200 then true
        when 404 then false
        else raise Failed, "GET of /contacts/#{id} answered #{response.status}: #{response.body}"
        end
      end
    end
  end
end
