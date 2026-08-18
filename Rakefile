# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "minitest/test_task"

Minitest::TestTask.create

desc "Start development server, reloading on changes"
task :dev do
  sh "fd -e rb . lib | entr -r rackup -o localhost"
end

desc "Regenerate macOS exchange response fixtures from current responses"
task :fixtures do
  ENV["RACK_ENV"] = "test"
  require "pro_tacts/web"
  require_relative "test/pro_tacts/exchange_fixtures"
  ExchangeFixtures.record_responses(ProTacts::Web)
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
  desc "Stage the configuration profile and open Settings → Profiles; click Install there"
  task install: "carddav.mobileconfig" do |task|
    sh "open", task.prerequisites.first
    sh "open", "x-apple.systempreferences:com.apple.preferences.configurationprofiles"
  end

  desc "Remove the configuration profile"
  task :remove do
    require "pro_tacts/profile"
    sh "profiles", "remove", "-identifier", ProTacts::Profile::PAYLOAD_IDENTIFIER
  end
end

task default: :test
