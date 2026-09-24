require "json"

module ProTacts
  class Web < Roda
    # JSON for scripts, beside the HTML screens a person uses. It was
    # written for `rake import:execute`, which looked a group up by
    # name over HTTP before making it; that import is gone
    # (docs/plans/2026-09-21-import-a-vcf.md) and the route stays as
    # what it always was — the group list, for anything scripted
    # pointed at this server, reading the order every listing does
    # (`Group#<=>`).
    hash_branch("api") do |r|
      r.get "groups" do
        response["Content-Type"] = "application/json"
        store.all_groups.sort.map { {id: it.id, name: it.name} }.to_json
      end
    end
  end
end
