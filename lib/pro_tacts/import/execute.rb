require "json"
require "uri"

require "pro_tacts/import/plan"

module ProTacts
  module Import
    # Lands a plan on a host through the routes a client and the admin
    # UI use, the same for every source. Idempotent against the host as
    # well as the plan (docs/plans/2026-09-16-importing-from-macos.md,
    # "Execute is the same for every source").
    class Execute
      # @rbs @plan: Plan
      # @rbs @host: String
      # @rbs @client: _Client
      # @rbs @group_ids: Hash[String, String]

      class Failed < StandardError; end

      # What a host answered. Signed in sig/pro_tacts/import.rbs, being a
      # Data class.
      # @rbs skip
      Response = Data.define(:status, :headers, :body)

      #: (Plan plan, host: String, client: _Client) -> void
      def self.call(plan, host:, client:)
        new(plan, host:, client:).call
      end

      #: (Plan plan, host: String, client: _Client) -> void
      def initialize(plan, host:, client:)
        @plan = plan
        @host = host
        @client = client
        @group_ids = {}
      end

      #: () -> void
      def call
        landed_on = @plan.host
        if landed_on && landed_on != @host
          raise Failed, "#{@plan.dir} is landing on #{landed_on}; refusing to land it on #{@host} too"
        end
        # Every card still to carry is read before the first write, so an
        # edit that will not read stops the run with nothing landed.
        cards = @plan.contacts.reject { it.status == "imported" }.to_h {
          [it.id, @plan.card(it.id)] #: [String, Card]
        }
        # Before the first write, so a run that dies after one still ties
        # the plan to this host.
        @plan.host = @host unless landed_on

        @plan.contacts.each { land(it.id, cards.fetch(it.id)) if it.status.nil? }
        @plan.contacts.each { add_to_groups(it.id, cards.fetch(it.id)) if it.status == "landed" }
      end

      private

      # A bare 412 is If-None-Match failing on an id this plan minted, so
      # the card is on the host already: an earlier run's PUT landed and
      # died before the plan recorded it. A 412 with a body is the card
      # refused.
      #: (String id, Card card) -> void
      def land(id, card)
        response = @client.call(
          "PUT", "/dav/addressbook/#{id}.vcf",
          headers: {"Content-Type" => "text/vcard; charset=utf-8", "If-None-Match" => "*"},
          body: card.contact(id).vcard.to_s
        )
        unless [201, 204].include?(response.status) || response.status == 412 && response.body.empty?
          raise Failed, "PUT of #{id} answered #{response.status}: #{response.body}"
        end

        @plan.record(id, "landed")
      end

      # The card's groups, and out of `sync:*` unless it is one of them:
      # the PUT that created the card put it there.
      #: (String id, Card card) -> void
      def add_to_groups(id, card)
        form = card.groups.uniq.map { ["groups[]", group_id(it)] } #: Array[[String, String]]
        form << ["was[]", group_id(Plan::EVERYONE)]
        response = post("/contacts/#{id}/groups", form)
        raise Failed, "adding #{id} to #{card.groups.join(", ")} answered #{response.status}" unless response.status == 303

        @plan.record(id, "imported")
      end

      # Looked up before it is made, so a run that died after making it
      # reuses the one it made.
      #: (String name) -> String
      def group_id(name)
        @group_ids[name] ||= listed_group_id(name) || make_group(name)
      end

      #: (String name) -> String
      def make_group(name)
        response = post("/groups", [["name", name]])
        raise Failed, "creating group #{name} answered #{response.status}" unless response.status == 303

        listed_group_id(name) or raise Failed, "group #{name} was created and is not listed"
      end

      #: (String name) -> String?
      def listed_group_id(name)
        response = @client.call("GET", "/api/groups")
        raise Failed, "listing groups answered #{response.status}" unless response.status == 200

        groups = JSON.parse(response.body) #: Array[Hash[String, String?]]
        groups.find { it.fetch("name") == name }&.fetch("id")
      end

      #: (String path, Array[[String, String]] form) -> Response
      def post(path, form)
        @client.call("POST", path, headers: {"Content-Type" => "application/x-www-form-urlencoded"}, body: URI.encode_www_form(form))
      end
    end
  end
end
