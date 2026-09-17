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
      end

      #: () -> void
      def call
        landed_on = @plan.host
        if landed_on && landed_on != @host
          raise Failed, "#{@plan.dir} is landing on #{landed_on}; refusing to land it on #{@host} too"
        end
        # Before the first write, so a run that dies after one still ties
        # the plan to this host.
        @plan.host = @host unless landed_on

        @plan.contacts.each { land(it.id) if it.status.nil? }
        group_id = @plan.group_id || make_group
        @plan.contacts.each { join(it.id, group_id) if it.status == "landed" }
      end

      private

      # A bare 412 is If-None-Match failing on an id this plan minted, so
      # the card is on the host already: an earlier run's PUT landed and
      # died before the plan recorded it. A 412 with a body is the card
      # refused.
      #: (String id) -> void
      def land(id)
        response = @client.call(
          "PUT", "/dav/addressbook/#{id}.vcf",
          headers: {"Content-Type" => "text/vcard; charset=utf-8", "If-None-Match" => "*"},
          body: @plan.card(id)
        )
        unless [201, 204].include?(response.status) || response.status == 412 && response.body.empty?
          raise Failed, "PUT of #{id} answered #{response.status}: #{response.body}"
        end

        @plan.record(id, "landed")
      end

      # Looked up before it is made, so a run that died after making it
      # joins the one it made.
      #: () -> String
      def make_group
        id = listed_group_id
        unless id
          response = post("/groups", [["name", @plan.group]])
          raise Failed, "creating group #{@plan.group} answered #{response.status}" unless response.status == 303

          id = listed_group_id or raise Failed, "group #{@plan.group} was created and is not listed"
        end

        @plan.group_id = id
        id
      end

      #: () -> String?
      def listed_group_id
        response = @client.call("GET", "/api/groups")
        raise Failed, "listing groups answered #{response.status}" unless response.status == 200

        groups = JSON.parse(response.body) #: Array[Hash[String, String?]]
        groups.find { it.fetch("name") == @plan.group }&.fetch("id")
      end

      #: (String id, String group_id) -> void
      def join(id, group_id)
        response = post("/contacts/#{id}/groups", [["groups[]", group_id]])
        raise Failed, "joining #{id} to #{@plan.group} answered #{response.status}" unless response.status == 303

        @plan.record(id, "joined")
      end

      #: (String path, Array[[String, String]] form) -> Response
      def post(path, form)
        @client.call("POST", path, headers: {"Content-Type" => "application/x-www-form-urlencoded"}, body: URI.encode_www_form(form))
      end
    end
  end
end
