require "pro_tacts/import/plan"

module ProTacts
  module Import
    # Finalizes a plan's contacts off this Mac, once they have landed
    # on a host (docs/plans/2026-09-16-importing-from-macos.md,
    # "Removing the originals"). Every check is a reason to keep a
    # contact rather than to delete one, because a wrong keep costs a
    # second look and a wrong delete costs the contact.
    class Finalize
      # @rbs @plan: Plan
      # @rbs @client: _Client
      # @rbs @mac: _Mac

      class Failed < StandardError; end

      # What a run did: how many contacts it took off the Mac, and the
      # ones it left there, each as its plan id, the name the plan recorded
      # and why it stayed. Both, since the person reading has a contact to
      # find in Contacts and a line to find in plan.yml. Signed in
      # sig/pro_tacts/import.rbs, being a Data class.
      # @rbs skip
      Result = Data.define(:done, :kept)

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
        # A contact this Mac no longer has is a contact done, which is
        # what a rerun of an interrupted run sees.
        gone.each { @plan.record(it.id, Plan::DONE) }

        kept = [] #: Array[[String, String, String]]
        going = still_there.select { |contact|
          why = keep(contact, records.fetch(contact.source_id))
          kept << [contact.id, contact.name, why] if why
          why.nil?
        }
        # One call for the batch, since each one starts the script again,
        # and one save request per contact inside it, so a contact the
        # store refuses is the only one that stays. A run that dies before
        # the plan records the rest finds them gone next time.
        refused = @mac.delete(going.map(&:source_id))
        deleted, stuck = going.partition { !refused.key?(it.source_id) }
        deleted.each { @plan.record(it.id, Plan::DONE) }
        stuck.each {
          kept << [it.id, it.name, "this Mac would not delete #{it.source_id}: #{refused.fetch(it.source_id)}"]
        }

        Result.new(done: gone.size + deleted.size, kept:)
      end

      private

      # Why this contact stays on the Mac, or nil for one to delete. The
      # comparison is exact because CNContact carries no modification
      # date: a contact Contacts.app rewrote on its own is kept, which is
      # the safe direction to be wrong in.
      #: (Plan::Contact contact, Hash[String, untyped] record) -> String?
      def keep(contact, record)
        source = @plan.card(contact.id).source
        if !on_host?(contact.id)
          "its card is no longer on #{@plan.host}"
        elsif record.fetch("vcard") != source.fetch("vcard")
          "it has changed on this Mac since the plan"
        elsif record.fetch("note") != source.fetch("note")
          "its note has changed on this Mac since the plan"
        end
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
