require "json"

module ProTacts
  class Web < Roda
    # JSON for scripts, beside the HTML screens a person uses: the
    # group list, in the order every listing reads (`Group#<=>`).
    hash_branch("api") do |r|
      r.get "groups" do
        response["Content-Type"] = "application/json"
        store.all_groups.sort.map { {id: it.id, name: it.name} }.to_json
      end
    end
  end
end
