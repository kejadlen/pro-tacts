# Importing an address book from another source
# (docs/plans/2026-09-16-importing-from-macos.md, and
# docs/plans/2026-09-19-import-under-data-import.md for the layout
# and the vocabulary).

require "fileutils"
require "pathname"

# The plan a task carries further. A module rather than task-file methods,
# which rake redefines noisily when a file is loaded twice.
module ImportTasks
  # All the import collateral under data/import: the standing
  # configuration in config.yml beside the plans, active under plans/
  # and filed away under done/ once every contact is off this Mac.
  PLANS = Pathname.new("data/import/plans")
  DONE = Pathname.new("data/import/done")

  # Where the import tasks keep their standing data between plans:
  # data/import/config.yml (ProTacts::Import::Config reads it).
  CONFIG = Pathname.new("data/import/config.yml")

  # What each carrying task waits on — a contact still to carry through
  # that step — named so a status read can say what those tasks would
  # pick next without restating their choice.
  TO_LAND = ->(plan) { plan.with_status(nil).any? || plan.with_status("landed").any? }
  TO_CLEAR = ->(plan) { plan.with_status("imported").any? }

  # The plan PLAN names, or the oldest one still waiting for this step:
  # plans are carried in the order they were built, so the next one to
  # take further is the oldest that has not been. A PLAN that is not a
  # directory is read as a plan's name under PLANS, the way the
  # directories there are named.
  def self.plan(waiting, step)
    named = ENV.fetch("PLAN", nil)&.then { Pathname.new(it) }
    named = PLANS / named if named && !named.directory?
    if named
      abort "#{named} holds no plan.yml" unless (named / "plan.yml").file?
      return ProTacts::Import::Plan.read(named)
    end

    ProTacts::Import::Plan.all(PLANS).find(&waiting) ||
      abort("no plan in #{PLANS} is waiting #{step}: run rake import:macos:plan, or name one in PLAN")
  end

  # A finished plan's final state: moved under DONE, nothing left to
  # carry. The clear task files one away as its last step; the status
  # read sweeps any a dead run left behind.
  def self.file_away(plan)
    FileUtils.mkdir_p(DONE)
    FileUtils.mv(plan.dir, DONE / plan.dir.basename)
  end
end

namespace :import do
  namespace :macos do
    desc "Plan importing this Mac's iCloud contacts into data/import/plans (LIMIT=n for the first n)"
    task :plan do
      require "pro_tacts/import/macos"

      created_at = Time.now.utc
      dir = ImportTasks::PLANS / "macos-#{created_at.strftime("%Y%m%dT%H%M%SZ")}"
      limit = ENV.fetch("LIMIT", nil)&.then { Integer(it) }

      records = ProTacts::Import::Macos.read(limit:)
      plan = ProTacts::Import::Macos.plan(dir, records, created_at:)
      phone = ->(row) { [row.fetch("number"), row["label"]].compact.join(" ") }
      plan.contacts.each do |contact|
        card = plan.card(contact.id)
        puts "#{contact.id}  #{contact.name}#{card.phones.map { "  #{phone.call(it)}" }.join}"
      end
      puts "#{plan.contacts.size} contacts planned in #{dir}"
    rescue ProTacts::Import::Macos::Unknown => error
      abort error.message
    end

    desc "Clear this Mac of the contacts the oldest landed plan imported, filing the plan away once its last contact is off (PLAN=dir for another)"
    task :clear do
      require "net/http"
      require "uri"
      require "pro_tacts/import/http_client"
      require "pro_tacts/import/macos"
      require "pro_tacts/import/clear"

      plan = ImportTasks.plan(ImportTasks::TO_CLEAR, "to clear")
      host = plan.host or abort("#{plan.dir} has not landed on a host")
      uri = URI.parse(host)
      puts "clearing the contacts #{plan.dir} landed on #{host}"

      result = nil #: ProTacts::Import::Clear::Result?
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        result = ProTacts::Import::Clear.call(
          plan, client: ProTacts::Import::HttpClient.new(http), mac: ProTacts::Import::Macos::Mac
        )
      end
      result.kept.each { |id, name, why| puts "kept #{id} #{name}: #{why}" }
      puts "#{result.cleared} contacts cleared from this Mac"
      if plan.done?
        ImportTasks.file_away(plan)
        puts "filed #{plan.dir.basename} away in #{ImportTasks::DONE}"
      end
    end
  end

  desc "Summarize the plans in data/import and what execute and clear would carry next"
  task :status do
    require "pro_tacts/import/plan"

    # A finished plan files away; this sweeps any a dead run left in
    # plans/, so what is listed is what still has work — which is also
    # why nothing here is ever finished: the sweep took it.
    ProTacts::Import::Plan.all(ImportTasks::PLANS).each do |plan|
      ImportTasks.file_away(plan) if plan.done?
    end

    plans = ProTacts::Import::Plan.all(ImportTasks::PLANS)
    if plans.empty?
      puts "no plans in #{ImportTasks::PLANS}; run rake import:macos:plan"
      next
    end

    # One line per plan, as far along as it is: the fraction counts
    # everything past “planned”, because from “landed” on the card is
    # on the host — which is the state a glance wants. The plan names
    # are the directories', copy-pasteable into PLAN=.
    plans.each do |plan|
      done = plan.contacts.size - plan.with_status(nil).size
      puts "#{plan.dir.basename}  #{done}/#{plan.contacts.size} contacts"
    end

    puts ""
    landing = plans.find(&ImportTasks::TO_LAND)
    clearing = plans.find(&ImportTasks::TO_CLEAR)
    puts "next: import:execute would land #{landing.dir.basename}" if landing
    puts "next: import:macos:clear would finish #{clearing.dir.basename}" if clearing
  end

  desc "Land the oldest plan in data/import/plans still to land, or the one in PLAN, on the pro-tacts at HOST, a base URL such as https://contacts"
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
