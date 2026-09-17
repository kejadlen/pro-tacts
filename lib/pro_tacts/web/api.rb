require "json"

module ProTacts
  class Web < Roda
    # JSON for scripts, beside the HTML screens a person uses. An import
    # looks its group up here by name before making it, so a rerun
    # joins the group an earlier run made
    # (docs/plans/2026-09-16-importing-from-macos.md).
    hash_branch("api") do |r|
      r.get "groups" do
        response["Content-Type"] = "application/json"
        store.all_groups.map { {id: it.id, name: it.name} }.to_json
      end
    end
  end
end
