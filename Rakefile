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

desc "Generate carddav.mobileconfig to provision the macOS account"
task :profile do
  require "pro_tacts/profile"

  # Throwaway credentials for the dev loop; real auth is its own backlog task.
  File.write("carddav.mobileconfig", ProTacts::Profile.render(
    hostname: ENV.fetch("PRO_TACTS_HOSTNAME"),
    username: "a@b.com",
    password: "a"
  ))
  identifier = ProTacts::Profile::PAYLOAD_IDENTIFIER
  puts <<~MESSAGE
    Wrote carddav.mobileconfig. Install:
      sudo profiles install -type configuration -path carddav.mobileconfig
    Remove:
      sudo profiles remove -identifier #{identifier}
    Recent macOS may ask you to approve the profile in System Settings → Profiles.
  MESSAGE
end

task default: :test
