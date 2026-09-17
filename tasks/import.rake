# Importing an address book from another source
# (docs/plans/2026-09-16-importing-from-macos.md).

namespace :import do
  desc "Land the plan in PLAN on the pro-tacts at HOST, a base URL such as https://contacts"
  task :execute do
    require "net/http"
    require "pathname"
    require "uri"
    require "pro_tacts/import/execute"
    require "pro_tacts/import/http_client"
    require "pro_tacts/import/plan"

    plan = ProTacts::Import::Plan.read(Pathname.new(ENV.fetch("PLAN")))
    host = ENV.fetch("HOST")
    uri = URI.parse(host)

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      ProTacts::Import::Execute.call(plan, host:, client: ProTacts::Import::HttpClient.new(http))
    end
    puts "#{plan.contacts.size} contacts in #{plan.group} on #{host}"
  end
end
