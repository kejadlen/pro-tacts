
require "pathname"

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
  # a fresh `rake dev` is what resets to the fixtures.
  data_dir = Pathname.new(__dir__) / "tmp" / "dev-data"
  ENV["PRO_TACTS_DATA_DIR"] = data_dir.to_s
  require_relative "test/fixture_data"
  FixtureData.install(data_dir).close
  sh "fd -e rb . lib | entr -r rackup -o localhost"
end

desc "Regenerate macOS exchange response fixtures from current responses"
task :fixtures do
  # Mirrors test/test_helper.rb, which cannot be required here without
  # minitest/autorun running its at_exit hook inside rake.
  data_dir = Pathname.new(__dir__) / "tmp" / "test-data"
  ENV["PRO_TACTS_DATA_DIR"] = data_dir.to_s
  require "pro_tacts/web"
  require_relative "test/fixture_data"
  require_relative "test/pro_tacts/exchange_fixtures"
  ProTacts::Web.store = FixtureData.install(data_dir)
  ExchangeFixtures.record_responses(ProTacts::Web)
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
