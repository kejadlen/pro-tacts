# Importing an address book from another source
# (docs/plans/2026-09-16-importing-from-macos.md).

require "pathname"

# The plan a task carries further. A module rather than task-file methods,
# which rake redefines noisily when a file is loaded twice.
module ImportTasks
  DIR = Pathname.new("data/imports")

  # What each carrying task waits on — a contact still to carry through
  # that step — named so a status read can say what those tasks would
  # pick next without restating their choice.
  TO_LAND = ->(plan) { plan.with_status(nil).any? || plan.with_status("landed").any? }
  TO_LEAVE = ->(plan) { plan.with_status("imported").any? }

  # The plan PLAN names, or the oldest one still waiting for this step:
  # plans are carried in the order they were built, so the next one to
  # take further is the oldest that has not been. A PLAN that is not a
  # directory is read as a plan's name under DIR, the way the directories
  # there are named.
  def self.plan(waiting, step)
    named = ENV.fetch("PLAN", nil)&.then { Pathname.new(it) }
    named = DIR / named if named && !named.directory?
    if named
      abort "#{named} holds no plan.yml" unless (named / "plan.yml").file?
      return ProTacts::Import::Plan.read(named)
    end

    ProTacts::Import::Plan.all(DIR).find(&waiting) ||
      abort("no plan in #{DIR} is waiting #{step}: run rake import:macos:plan, or name one in PLAN")
  end
end

namespace :import do
  namespace :macos do
    desc "Plan importing this Mac's iCloud contacts into data/imports (LIMIT=n for the first n)"
    task :plan do
      require "pro_tacts/import/macos"

      created_at = Time.now.utc
      dir = ImportTasks::DIR / "macos-#{created_at.strftime("%Y%m%dT%H%M%SZ")}"
      limit = ENV.fetch("LIMIT", nil)&.then { Integer(it) }

      records = ProTacts::Import::Macos.read(limit:)
      plan = ProTacts::Import::Macos.plan(dir, records, created_at:)
      plan.contacts.each do |contact|
        card = plan.card(contact.id)
        puts "#{contact.id}  #{contact.name}#{card.phones.map { "  #{it}" }.join}"
      end
      puts "#{plan.contacts.size} contacts planned in #{dir}"
    rescue ProTacts::Import::Macos::Unknown => error
      abort error.message
    end

    desc "Delete from this Mac the contacts the oldest landed plan imported (PLAN=dir for another)"
    task :remove do
      require "net/http"
      require "uri"
      require "pro_tacts/import/http_client"
      require "pro_tacts/import/macos"
      require "pro_tacts/import/remove"

      plan = ImportTasks.plan(ImportTasks::TO_LEAVE, "to leave this Mac")
      host = plan.host or abort("#{plan.dir} has not landed on a host")
      uri = URI.parse(host)
      puts "removing the contacts #{plan.dir} landed on #{host}"

      result = nil #: ProTacts::Import::Remove::Result?
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        result = ProTacts::Import::Remove.call(
          plan, client: ProTacts::Import::HttpClient.new(http), mac: ProTacts::Import::Macos::Mac
        )
      end
      result.kept.each { |id, name, why| puts "kept #{id} #{name}: #{why}" }
      puts "#{result.removed} contacts removed from this Mac"
    end
  end

  desc "Summarize the imports in data/imports and what execute and remove would carry next"
  task :status do
    require "pro_tacts/import/plan"

    plans = ProTacts::Import::Plan.all(ImportTasks::DIR)
    if plans.empty?
      puts "no plans in #{ImportTasks::DIR} yet; run rake import:macos:plan"
      next
    end

    # One line per plan, as far along as it is: the fraction counts
    # everything past “planned”, because from “landed” on the card is
    # on the host — which is the state a glance wants. The marker is
    # ✅ once nothing is left for import:execute to carry — every
    # contact imported or beyond — and ⏳ until then, so it can never
    # disagree with the next lines below. The plan names are the
    # directories', copy-pasteable into PLAN=.
    plans.each do |plan|
      done = plan.contacts.size - plan.with_status(nil).size
      marker = ImportTasks::TO_LAND.call(plan) ? "⏳" : "✅"
      puts "#{marker} #{plan.dir.basename}  #{done}/#{plan.contacts.size} contacts"
    end

    puts ""
    landing = plans.find(&ImportTasks::TO_LAND)
    leaving = plans.find(&ImportTasks::TO_LEAVE)
    puts "next: import:execute would land #{landing.dir.basename}" if landing
    puts "next: import:macos:remove would clear #{leaving.dir.basename}" if leaving
  end

  desc "Land the oldest plan in data/imports still to land, or the one in PLAN, on the pro-tacts at HOST, a base URL such as https://contacts"
  task :execute do
    require "net/http"
    require "uri"
    require "pro_tacts/import/execute"
    require "pro_tacts/import/http_client"
    require "pro_tacts/import/plan"

    plan = ImportTasks.plan(ImportTasks::TO_LAND, "to land")
    # A bare hostname is the base URL of a server that serves HTTPS, which
    # every deployment does; the scheme is spelled out here so the host
    # the plan records is the one a second run is compared against.
    uri = URI.parse(ENV.fetch("HOST"))
    uri = URI.parse("https://#{uri}") if uri.scheme.nil?
    host = uri.to_s
    puts "landing #{plan.dir} on #{host}"

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      ProTacts::Import::Execute.call(plan, host:, client: ProTacts::Import::HttpClient.new(http))
    end
    groups = plan.contacts.flat_map { plan.card(it.id).groups }.uniq
    puts "#{plan.contacts.size} contacts in #{groups.join(", ")} on #{host}"
  end
end
