require_relative "../../test_helper"

require "pathname"
require "rack/mock"
require "tmpdir"

require "pro_tacts/import/execute"
require "pro_tacts/import/plan"
require "pro_tacts/web"

class ImportExecuteTest < Minitest::Test
  include ThrowawayContacts

  Plan = ProTacts::Import::Plan
  Execute = ProTacts::Import::Execute

  HOST = "https://contacts"
  IDS = %w[kmnuqmzxylru vmnlryyvktux].freeze

  # The app in place of a host, the proxy's identity header included.
  class RackClient
    attr_reader :requests

    def initialize
      @requests = []
    end

    def call(method, path, headers: {}, body: nil)
      @requests << [method, path]
      env = Rack::MockRequest.env_for(path, method:, input: body, "HTTP_REMOTE_USER" => "test@example.com")
      headers.each { |name, value| env[name.casecmp?("Content-Type") ? "CONTENT_TYPE" : "HTTP_#{name.upcase.tr("-", "_")}"] = value }
      status, response_headers, response_body = ProTacts::Web.call(env)
      bytes = +""
      response_body.each { bytes << it }
      response_body.close if response_body.respond_to?(:close)
      Execute::Response.new(status:, headers: response_headers, body: bytes)
    end
  end

  # A client whose host refuses every PUT with a precondition body.
  class RefusingClient < RackClient
    def call(method, path, headers: {}, body: nil)
      return Execute::Response.new(status: 412, headers: {}, body: "<error/>") if method == "PUT"

      super
    end
  end

  def with_plan(groups: [])
    Dir.mktmpdir do |tmp|
      dir = Pathname.new(tmp) / "plan"
      entries = IDS.map { |id|
        card = ProTacts::Import::Card.new(first: "Contact", last: id, phones: [], groups:)
        Plan::Entry.new(id:, source_id: "#{id}:ABPerson", card:, backup: {})
      }
      Plan.write(dir, source: "macos", created_at: Time.utc(2026, 9, 16, 18, 4, 12), entries:)
      with_contacts({}) { |store| yield Plan.read(dir), store, RackClient.new }
    end
  end

  def imported_group(store) = group_named(store, "import-20260916T180412Z")

  def everyone(store) = group_named(store, "sync:*")

  def group_named(store, name)
    store.all_groups.find { it.name == name }
  end

  def edit_cards(plan)
    IDS.each do |id|
      path = plan.dir / "cards/#{id}.yml"
      path.write(yield(path.read))
    end
  end

  def test_every_card_lands_in_the_plans_group
    with_plan do |plan, store, client|
      Execute.call(plan, host: HOST, client:)

      IDS.each { assert_equal "Contact #{it}", store.contact(it).name }
      assert_equal IDS.sort, imported_group(store).members.sort
      assert_equal IDS.sort, everyone(store).members.sort
      assert_equal %w[imported imported], Plan.read(plan.dir).contacts.map(&:status)
    end
  end

  def test_a_rerun_writes_nothing_again
    with_plan do |plan, store, client|
      Execute.call(plan, host: HOST, client:)
      changes = store.changes.size
      client.requests.clear

      Execute.call(Plan.read(plan.dir), host: HOST, client:)

      assert_empty client.requests
      assert_equal changes, store.changes.size
      assert_equal 1, store.all_groups.count { it.name == "import-20260916T180412Z" }
    end
  end

  # A run that died between a write and the plan recording it.
  def test_a_card_already_on_the_host_counts_as_landed
    with_plan do |plan, store, client|
      client.call("PUT", "/dav/addressbook/#{IDS.first}.vcf", headers: {"Content-Type" => "text/vcard"}, body: plan.card(IDS.first).contact(IDS.first).vcard.to_s)

      Execute.call(plan, host: HOST, client:)

      assert_equal IDS.sort, imported_group(store).members.sort
    end
  end

  def test_a_group_already_on_the_host_is_joined_rather_than_made_again
    with_plan do |plan, store, client|
      id = store.create_group(name: "import-20260916T180412Z")

      Execute.call(plan, host: HOST, client:)

      assert_equal id, imported_group(store).id
      assert_equal IDS.sort, store.group(id).members.sort
    end
  end

  def test_a_plan_that_landed_on_one_host_refuses_another
    with_plan do |plan, store, client|
      Execute.call(plan, host: HOST, client:)

      error = assert_raises(Execute::Failed) { Execute.call(Plan.read(plan.dir), host: "http://localhost:9292", client:) }
      assert_includes error.message, HOST
    end
  end

  def test_a_refused_card_stops_the_run_and_is_not_recorded
    with_plan do |plan, _store, _client|
      error = assert_raises(Execute::Failed) { Execute.call(plan, host: HOST, client: RefusingClient.new) }

      assert_includes error.message, IDS.first
      assert_includes error.message, "412"
      assert_equal [nil, nil], Plan.read(plan.dir).contacts.map(&:status)
    end
  end

  def test_a_card_joins_the_groups_its_file_names_making_those_missing
    with_plan(groups: ["family"]) do |plan, store, client|
      Execute.call(plan, host: HOST, client:)

      assert_equal IDS.sort, group_named(store, "family").members.sort
      assert_equal 1, store.all_groups.count { it.name == "family" }
    end
  end

  def test_a_card_whose_file_leaves_out_everyone_is_taken_out_of_it
    with_plan do |plan, store, client|
      edit_cards(plan) { it.sub("- sync:*\n", "") }

      Execute.call(plan, host: HOST, client:)

      assert_empty everyone(store).members
      assert_equal IDS.sort, imported_group(store).members.sort
    end
  end

  def test_a_card_that_will_not_read_stops_the_run_before_anything_lands
    with_plan do |plan, store, client|
      path = plan.dir / "cards/#{IDS.last}.yml"
      path.write(path.read.sub("last: #{IDS.last}", "last: no"))

      assert_raises(ProTacts::Import::Card::Invalid) { Execute.call(plan, host: HOST, client:) }

      assert_empty client.requests
      assert_nil Plan.read(plan.dir).host
      assert_empty store.changes
    end
  end
end
