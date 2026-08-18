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
      identifiers.each { |identifier| sh "profiles", "remove", "-identifier", identifier }
    end
  end
end

task default: :test
