require_relative "../test_helper"

require "json"
require "rack/test"

require "pro_tacts/web"

class ApiTest < Minitest::Test
  include Rack::Test::Methods
  include ThrowawayContacts

  def app
    ProTacts::Web
  end

  def setup
    header "Remote-User", "test@example.com"
  end

  def test_groups_lists_every_group_by_id_and_name
    with_contacts({}) do |store|
      %w[import-20260916T180412Z sync:alpha aardvarks].each { store.create_group(name: it) }
      nameless = store.create_group
      ids = store.all_groups.to_h { [it.name, it.id] }

      get "/api/groups"

      assert_equal 200, last_response.status
      assert_equal "application/json", last_response["Content-Type"]
      groups = JSON.parse(last_response.body)
      # The nameless group's label is its id, so where it falls
      # among the named is not fixed.
      listed = groups.map { it.fetch("id") }
      named = %w[sync:alpha aardvarks import-20260916T180412Z].map { ids.fetch(it) }
      assert_equal named, listed & named
      assert_equal "sync:alpha", groups.fetch(0).fetch("name")
      assert_includes groups, {"id" => nameless, "name" => nil}
    end
  end

  def test_an_unknown_api_path_is_404
    with_contacts({}) do
      get "/api/nope"

      assert_equal 404, last_response.status
    end
  end
end
