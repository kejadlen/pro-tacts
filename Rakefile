
require "pathname"
require "tmpdir"

$LOAD_PATH.unshift(Pathname.new(__dir__) / "lib")
require "minitest/test_task"

Minitest::TestTask.create

Dir.glob("tasks/*.rake").sort.each do
  import it
end

desc "Start development server, reloading on changes"
task :dev do
  # The dev server serves the fixture book, rebuilt from
  # test/fixtures/cards on every start, so a client always sees known
  # state and the real data/ directory stays out of the dev loop. Only
  # rackup reloads under entr, so a client's edits survive a restart and
  # a fresh `rake dev` is what resets to the fixtures. The data lives in
  # a session-scoped tmpdir: two servers running at once each get their
  # own database, and the directory goes when the task does.
  # A dev session's debug exchanges go to their own log, truncated per
  # start, so reading a session back never means picking it out of older
  # ones — log/debug.log stays the deployment default. An exported
  # PRO_TACTS_DEBUG_LOG (e.g. stderr) wins over both.
  ENV["PRO_TACTS_DEBUG_LOG"] ||= "log/dev.log"
  File.truncate("log/dev.log", 0) if File.exist?("log/dev.log")

  Dir.mktmpdir("pro-tacts-dev") do |dir|
    data_dir = Pathname.new(dir)
    ENV["PRO_TACTS_DATA_DIR"] = data_dir.to_s
    require_relative "test/fixture_data"
    FixtureData.install(data_dir).close
    sh "fd -e rb . lib | entr -r rackup -o localhost"
  end
end

desc "Regenerate macOS exchange response fixtures from current responses"
task :fixtures do
  # Mirrors test/test_helper.rb, which cannot be required here without
  # minitest/autorun running its at_exit hook inside rake. Its own
  # tmpdir, so a fixture re-record cannot race a concurrent test run.
  # The debug log dies with that tmpdir too: the fixture files are the
  # durable record of a re-record, and a replay's exchanges must not
  # append to a log a real client session also uses.
  Dir.mktmpdir("pro-tacts-test") do |dir|
    data_dir = Pathname.new(dir)
    ENV["PRO_TACTS_DATA_DIR"] = data_dir.to_s
    ENV["PRO_TACTS_DEBUG_LOG"] ||= (data_dir / "debug.log").to_s
    require "pro_tacts/web"
    require_relative "test/fixture_data"
    require_relative "test/pro_tacts/exchange_fixtures"
    ProTacts::Web.store = FixtureData.install(data_dir)
    ExchangeFixtures.record_responses(ProTacts::Web)
  end
end

desc "Type check lib against the RBS comments in it"
task :steep do
  sh "steep", "check"
end

desc "Render the macOS configuration profile (carddav.mobileconfig)"
task profile: "carddav.mobileconfig"

# Rebuilds when the template changes but not when PRO_TACTS_HOSTNAME does;
# delete carddav.mobileconfig to force a rerender.
file "carddav.mobileconfig" => "lib/pro_tacts/profile.rb" do |task|
  require "pro_tacts/profile"

  File.write(task.name, ProTacts::Profile.render(
    hostname: ENV.fetch("PRO_TACTS_HOSTNAME")
  ))
end

namespace :profile do
  desc "Remove installed pro-tacts profiles, then stage a fresh one for approval"
  task install: :remove do
    require "pro_tacts/profile"

    File.write("carddav.mobileconfig", ProTacts::Profile.render(
      hostname: ENV.fetch("PRO_TACTS_HOSTNAME")
    ))
    sh "open", "carddav.mobileconfig"
    sh "open", "x-apple.systempreferences:com.apple.preferences.configurationprofiles"
  end

  desc "Remove every installed pro-tacts configuration profile"
  task :remove do
    require "pro_tacts/profile"

    identifiers = ProTacts::Profile.installed_identifiers(`profiles list`)
    if identifiers.empty?
      puts "No pro-tacts profiles found; remove by hand in System Settings → Profiles if one lingers."
    else
      identifiers.each do
        sh "profiles", "remove", "-identifier", it
      end
    end
  end
end

task default: %i[ steep test ]
