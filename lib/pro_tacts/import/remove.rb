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
      # ones it left there, each with why. Signed in
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
          kept << [contact.id, why] if why
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
          "its card is not on #{@plan.host}"
        elsif record.fetch("vcard") != (backup / "original.vcf").read
          "it has changed on this Mac since the plan"
        elsif record.fetch("note") != note
          "its note has changed on this Mac since the plan"
        end
      end

      #: (String id) -> bool
      def on_host?(id)
        response = @client.call("GET", "/dav/addressbook/#{id}.vcf")
        case response.status
        when 200 then true
        when 404 then false
        else raise Failed, "GET of #{id} answered #{response.status}"
        end
      end
    end
  end
end
