# Importing an address book from another source
# (docs/plans/2026-09-16-importing-from-macos.md).

namespace :import do
  namespace :macos do
    desc "Plan importing this Mac's iCloud contacts into data/imports (LIMIT=n for the first n)"
    task :plan do
      require "pathname"
      require "pro_tacts/import/macos"

      created_at = Time.now.utc
      dir = Pathname.new("data/imports/macos-#{created_at.strftime("%Y%m%dT%H%M%SZ")}")
      limit = ENV.fetch("LIMIT", nil)&.then { Integer(it) }

      records = ProTacts::Import::Macos.read(limit:)
      plan = ProTacts::Import::Macos.plan(dir, records, created_at:)
      plan.contacts.each do |contact|
        card = plan.card(contact.id)
        name = [card.first, card.last].reject(&:empty?).join(" ")
        puts "#{contact.id}  #{name}#{card.phones.map { "  #{it}" }.join}"
      end
      puts "#{plan.contacts.size} contacts planned in #{dir}"
    rescue ProTacts::Import::Macos::Unknown => error
      abort error.message
    end
  end

  desc "Land the newest plan in data/imports, or the one in PLAN, on the pro-tacts at HOST, a base URL such as https://contacts"
  task :execute do
    require "net/http"
    require "pathname"
    require "uri"
    require "pro_tacts/import/execute"
    require "pro_tacts/import/http_client"
    require "pro_tacts/import/plan"

    # The plan task writes under data/imports, and names each plan for the
    # minute it was built, so the newest is the one just planned. A PLAN
    # that is not a directory is read as a plan's name under there, the
    # way the directories there are named.
    named = ENV.fetch("PLAN", nil)&.then { Pathname.new(it) }
    named = Pathname.new("data/imports") / named if named && !named.directory?
    dir = named ||
      Pathname.glob("data/imports/*/plan.yml").map(&:dirname).max_by { it.basename.to_s } ||
      abort("no plan in data/imports: run rake import:macos:plan, or name one in PLAN")
    abort("#{dir} holds no plan.yml") unless (dir / "plan.yml").file?

    plan = ProTacts::Import::Plan.read(dir)
    # A bare hostname is the base URL of a server that serves HTTPS, which
    # every deployment does; the scheme is spelled out here so the host
    # the plan records is the one a second run is compared against.
    uri = URI.parse(ENV.fetch("HOST"))
    uri = URI.parse("https://#{uri}") if uri.scheme.nil?
    host = uri.to_s
    puts "landing #{dir} on #{host}"

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      ProTacts::Import::Execute.call(plan, host:, client: ProTacts::Import::HttpClient.new(http))
    end
    groups = plan.contacts.flat_map { plan.card(it.id).groups }.uniq
    puts "#{plan.contacts.size} contacts in #{groups.join(", ")} on #{host}"
  end
end
