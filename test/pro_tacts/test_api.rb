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
      named = store.create_group(name: "import-20260916T180412Z")
      nameless = store.create_group

      get "/api/groups"

      assert_equal 200, last_response.status
      assert_equal "application/json", last_response["Content-Type"]
      groups = JSON.parse(last_response.body)
      assert_equal store.all_groups.map { {"id" => it.id, "name" => it.name} }, groups
      assert_includes groups, {"id" => named, "name" => "import-20260916T180412Z"}
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
