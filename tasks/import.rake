# Importing an address book from another source
# (docs/plans/2026-09-16-importing-from-macos.md, and
# docs/plans/2026-09-19-import-under-data-import.md for the layout
# and the vocabulary).

require "fileutils"
require "pathname"
require "uri"

require "pro_tacts/import/config"

# The plan a task carries further. A module rather than task-file methods,
# which rake redefines noisily when a file is loaded twice.
module ImportTasks
  Config = ProTacts::Import::Config

  # What each carrying task waits on — a contact still to carry through
  # that step — named so a status read can say what those tasks would
  # pick next without restating their choice.
  TO_LAND = ->(plan) { plan.with_status(nil).any? || plan.with_status("landed").any? }
  TO_FINALIZE = ->(plan) { plan.with_status("imported").any? }

  # The plan PLAN names, or the oldest one still waiting for this step:
  # plans are carried in the order they were built, so the next one to
  # take further is the oldest that has not been. A PLAN that is not a
  # directory is read as a plan's name under Config::ACTIVE, the way
  # the directories there are named.
  def self.plan(waiting, step)
    named = ENV.fetch("PLAN", nil)&.then { Pathname.new(it) }
    named = Config::ACTIVE / named if named && !named.directory?
    if named
      abort "#{named} holds no plan.yml" unless (named / "plan.yml").file?
      return ProTacts::Import::Plan.read(named)
    end

    ProTacts::Import::Plan.all(Config::ACTIVE).find(&waiting) ||
      abort("no plan in #{Config::ACTIVE} is waiting #{step}: run rake import:macos:plan, or name one in PLAN")
  end

  # A finished plan's final state: moved under Config::DONE, nothing
  # left to carry. The finalize task files one away as its last step;
  # the status read sweeps any a dead run left behind.
  def self.file_away(plan)
    FileUtils.mkdir_p(Config::DONE)
    FileUtils.mv(plan.dir, Config::DONE / plan.dir.basename)
  end
end

namespace :import do
  namespace :macos do
    desc "Plan importing this Mac's iCloud contacts into data/import/active (LIMIT=n for the first n)"
    task :plan do
      require "pro_tacts/import/macos"

      created_at = Time.now.utc
      dir = ImportTasks::Config::ACTIVE / "macos-#{created_at.strftime("%Y%m%dT%H%M%SZ")}"
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

    desc "Finalize the contacts the oldest landed plan imported, taking them off this Mac and filing the plan away done (PLAN=dir for another)"
    task :finalize do
      require "net/http"
      require "pro_tacts/import/http_client"
      require "pro_tacts/import/macos"
      require "pro_tacts/import/finalize"

      plan = ImportTasks.plan(ImportTasks::TO_FINALIZE, "to finalize")
      host = plan.host or abort("#{plan.dir} has not landed on a host")
      uri = URI.parse(host)
      puts "finalizing the contacts #{plan.dir} landed on #{host}"

      result = nil #: ProTacts::Import::Finalize::Result?
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        result = ProTacts::Import::Finalize.call(
          plan, client: ProTacts::Import::HttpClient.new(http), mac: ProTacts::Import::Macos::Mac
        )
      end
      result.kept.each { |id, name, why| puts "kept #{id} #{name}: #{why}" }
      puts "#{result.done} contacts finalized"
      if plan.done?
        ImportTasks.file_away(plan)
        puts "filed #{plan.dir.basename} away in #{ImportTasks::Config::DONE}"
      end
    end
  end

  desc "Summarize the plans in data/import — in flight and filed away done — and what execute and finalize would carry next"
  task :status do
    require "pro_tacts/import/plan"

    # A finished plan files away; this sweeps any a dead run left in
    # active/, so the in-flight list below is what still has work —
    # which is also why nothing in it is ever finished: the sweep took
    # it.
    ProTacts::Import::Plan.all(ImportTasks::Config::ACTIVE).each do |plan|
      ImportTasks.file_away(plan) if plan.done?
    end

    plans = ProTacts::Import::Plan.all(ImportTasks::Config::ACTIVE)
    filed = ProTacts::Import::Plan.all(ImportTasks::Config::DONE)
    if plans.empty? && filed.empty?
      puts "no plans in #{ImportTasks::Config::ACTIVE}; run rake import:macos:plan"
      next
    end

    # One line per plan in flight, as far along as it is: the fraction
    # counts everything past “planned”, because from “landed” on the
    # card is on the host — which is the state a glance wants. The
    # plan names are the directories', copy-pasteable into PLAN=.
    in_flight = plans.map {
      carried = it.contacts.size - it.with_status(nil).size
      "#{it.dir.basename}  #{carried}/#{it.contacts.size} contacts"
    }

    landing = plans.find(&ImportTasks::TO_LAND)
    finalizing = plans.find(&ImportTasks::TO_FINALIZE)
    next_up = [
      ("next: import:execute would land #{landing.dir.basename}" if landing),
      ("next: import:macos:finalize would finish #{finalizing.dir.basename}" if finalizing),
    ].compact

    # What was carried through, whole counts because every contact
    # reached the final state — the fraction above can never appear
    # here.
    done = filed.map { "#{it.dir.basename}  #{it.contacts.size} contacts" }

    # Sections separated by a blank line only where one follows
    # another, so a status with no plans in flight says nothing of
    # next steps and still reports its history.
    sections = [in_flight, next_up, done.empty? ? [] : ["done:", *done]].reject(&:empty?)
    puts sections.map { it.join("\n") }.join("\n\n")
  end

  desc "Land the oldest plan in data/import/active still to land, or the one in PLAN, on the pro-tacts at the host in data/import/config.yml, a base URL such as https://contacts"
  task :execute do
    require "net/http"
    require "pro_tacts/import/execute"
    require "pro_tacts/import/http_client"
    require "pro_tacts/import/plan"

    plan = ImportTasks.plan(ImportTasks::TO_LAND, "to land")
    uri = ImportTasks::Config.read.host
    puts "landing #{plan.dir} on #{uri}"

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      ProTacts::Import::Execute.call(plan, host: uri.to_s, client: ProTacts::Import::HttpClient.new(http))
    end
    groups = plan.contacts.flat_map { plan.card(it.id).groups }.uniq
    puts "#{plan.contacts.size} contacts in #{groups.join(", ")} on #{uri}"
  end
end
