
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
  # entr's watch list is fd's snapshot at launch: a file created
  # after `rake dev` starts is never watched, and edits to it never
  # reload the server — restart the task when work adds a file.
  # A dev session's exchanges go to their own log, truncated per start,
  # so reading a session back never means picking it out of older ones —
  # log/exchange.log stays the deployment default. An exported
  # PRO_TACTS_EXCHANGE_LOG (e.g. stderr) wins over both.
  ENV["PRO_TACTS_EXCHANGE_LOG"] ||= "log/dev.log"
  File.truncate("log/dev.log", 0) if File.exist?("log/dev.log")

  Dir.mktmpdir("pro-tacts-dev") do |dir|
    data_dir = Pathname.new(dir)
    ENV["PRO_TACTS_DATA_DIR"] = data_dir.to_s
    require_relative "test/fixture_data"
    FixtureData.install(data_dir).close
    sh "fd -e rb . lib | entr -r rackup -o localhost"
  end
end

desc "Regenerate the recorded exchange response fixtures from current responses"
task :fixtures do
  # Mirrors test/test_helper.rb, which cannot be required here without
  # minitest/autorun running its at_exit hook inside rake. Its own
  # tmpdir, so a fixture re-record cannot race a concurrent test run.
  # The exchange log dies with that tmpdir too: the fixture files are the
  # durable record of a re-record, and a replay's exchanges must not
  # append to a log a real client session also uses.
  Dir.mktmpdir("pro-tacts-test") do |dir|
    data_dir = Pathname.new(dir)
    ENV["PRO_TACTS_DATA_DIR"] = data_dir.to_s
    ENV["PRO_TACTS_EXCHANGE_LOG"] ||= (data_dir / "exchange.log").to_s
    require "pro_tacts/web"
    require_relative "test/fixture_data"
    require_relative "test/pro_tacts/exchange_fixtures"

    # A store per recording, seeded fresh: the iOS session ends by
    # deleting a card, and the recording after it must not start from
    # what that one left behind.
    ExchangeFixtures.all.each do |recording|
      store = FixtureData.install(data_dir / recording.directory.basename)
      ProTacts::Web.store = store
      recording.record_responses(ProTacts::Web)
      store.close
    end
  end
end

desc "Type check lib against the RBS comments in it"
task :steep do
  sh "steep", "check"
end

namespace :profile do
  # The profile comes from the running app rather than a render here: the
  # route is the renderer (ProTacts::Web's setup branch), it writes the
  # requester's own login into the account where a render here had no
  # request to read one from, and a host that answers the download is a
  # host the account can reach. The download needs the identity header
  # the app reads, so it works against a deployment behind a proxy that
  # writes it and not against a server with nothing in front.
  #
  # Downloaded before the sweep rather than after, so a download that
  # fails leaves the installed account where it was.
  desc "Download the profile from PRO_TACTS_HOSTNAME and stage it for approval"
  task :install do
    sh "curl", "--fail", "--silent", "--show-error", "--location",
      "--output", "carddav.mobileconfig",
      "https://#{ENV.fetch("PRO_TACTS_HOSTNAME")}/setup/carddav.mobileconfig"

    Rake::Task["profile:remove"].invoke

    sh "open", "carddav.mobileconfig"
    sh "open", "x-apple.systempreferences:com.apple.preferences.configurationprofiles"
  end

  desc "Remove the installed configuration profiles pointing at PRO_TACTS_HOSTNAME"
  task :remove do
    require "pro_tacts/profile"

    list = `profiles list`
    hostname = ENV.fetch("PRO_TACTS_HOSTNAME")
    identifiers = ProTacts::Profile.installed_identifiers(list, hostname:)
    if identifiers.empty?
      puts "No #{hostname} profiles found; remove by hand in System Settings → Profiles if one lingers."
    else
      identifiers.each do
        sh "profiles", "remove", "-identifier", it
      end
    end

    # A profile pointing at another host provisions another server's
    # account — the deployment's, beside a dev one — and removing it would
    # take that account down with it. A profile from before the host was
    # part of the identifier says nothing about where it points, so it is
    # reported rather than swept.
    others = ProTacts::Profile.installed_identifiers(list, hostname: nil) - identifiers
    unless others.empty?
      puts "Left installed, from another host or an older identifier (remove by hand if stale):", *others
    end
  end
end

task default: %i[ steep test ]
