# Importing an address book from another source
# (docs/plans/2026-09-16-importing-from-macos.md,
# docs/plans/2026-09-19-import-under-data-import.md for the layout
# and the vocabulary, and docs/plans/2026-09-20-import-by-upload.md
# for the middle step, which is a screen in the app rather than a
# task here).

require "fileutils"
require "pathname"

require "pro_tacts/import/config"

# The plan a task carries further. A module rather than task-file methods,
# which rake redefines noisily when a file is loaded twice.
module ImportTasks
  Config = ProTacts::Import::Config

  # What the one carrying task left here waits on — a contact still to
  # finish — named so a status read can say what it would pick next
  # without restating its choice. Landing is the import screen's, and
  # writes nothing back to a plan, so a contact is outstanding until
  # finalize takes it off this Mac.
  TO_FINALIZE = ->(plan) { plan.outstanding.any? }

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

    desc "Finalize the contacts the oldest unfinished plan landed, taking them off this Mac and filing the plan away done (PLAN=dir for another)"
    task :finalize do
      require "net/http"
      require "pro_tacts/import/http_client"
      require "pro_tacts/import/macos"
      require "pro_tacts/import/finalize"

      plan = ImportTasks.plan(ImportTasks::TO_FINALIZE, "to finalize")
      # The host in the config rather than one the plan recorded: the
      # import screen lands a plan and writes nothing back to it, so the
      # config is the only place a host is named
      # (docs/plans/2026-09-20-import-by-upload.md). Finalize asks it
      # about every contact before deleting any, so a plan whose cards
      # were never uploaded keeps all of them.
      uri = ImportTasks::Config.read.host
      puts "finalizing the contacts #{plan.dir} landed on #{uri}"

      result = nil #: ProTacts::Import::Finalize::Result?
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        result = ProTacts::Import::Finalize.call(
          plan, host: uri.to_s, client: ProTacts::Import::HttpClient.new(http), mac: ProTacts::Import::Macos::Mac
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

  desc "Summarize the plans in data/import — in flight and filed away done — and what would carry the next one further"
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

    # One line per plan in flight, as far along as it is. The fraction
    # counts the contacts finalized, which is the only progress a plan
    # still records: landing happens in the app and leaves no mark here
    # (docs/plans/2026-09-20-import-by-upload.md), so a glance answers
    # “how much of this is off the Mac”. The plan names are the
    # directories', copy-pasteable into PLAN=.
    in_flight = plans.map {
      "#{it.dir.basename}  #{it.contacts.size - it.outstanding.size}/#{it.contacts.size} finalized"
    }

    finalizing = plans.find(&ImportTasks::TO_FINALIZE)
    next_up = finalizing ? [
      "next: /import would land the cards of #{finalizing.dir.basename}",
      "next: import:macos:finalize would finish #{finalizing.dir.basename}",
    ] : []

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
end
