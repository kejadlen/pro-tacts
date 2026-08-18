# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "digest"
require "rbconfig"
require "fileutils"
require "tmpdir"
require "hegel/libhegel_version"

require "minitest/test_task"

Minitest::TestTask.create

# The hegeltest gem drives a native libhegel engine that ships separately
# (the gem is pre-release and bundles no binary yet). This task stages it
# for the host platform: the release asset matching the gem's engine
# version, downloaded with gh (which handles the CDN redirects), verified
# against its published SHA-256, and installed under tmp/libhegel/<version>/
# (gitignored). The version comes from the gem — the binding targets a
# specific engine ABI, so the gem is the source of truth, not this file.
# The directory form of HEGEL_LIBHEGEL_PATH in .envrc resolves whichever
# platform's asset landed there.
LIBHEGEL_VERSION = Hegel::LIBHEGEL_VERSION
LIBHEGEL_ASSETS = {
  "arm64-darwin" => "libhegel-darwin-arm64.dylib",
  "aarch64-linux" => "libhegel-linux-arm64.so",
  "x86_64-linux" => "libhegel-linux-amd64.so"
}.freeze

# RbConfig's host_os carries version detail ("darwin25", "linux-gnu") that
# the asset table does not key on.
def libhegel_asset_name
  os = RbConfig::CONFIG.fetch("host_os")
  os = "darwin" if os.start_with?("darwin")
  os = "linux" if os.start_with?("linux")
  LIBHEGEL_ASSETS.fetch("#{RbConfig::CONFIG.fetch('host_cpu')}-#{os}")
rescue KeyError
  raise "no published libhegel for #{RbConfig::CONFIG.fetch('host_cpu')}-#{RbConfig::CONFIG.fetch('host_os')}; build one and point HEGEL_LIBHEGEL_PATH at it"
end

LIBHEGEL_DIR = File.expand_path("tmp/libhegel/#{LIBHEGEL_VERSION}", __dir__)
LIBHEGEL_PATH = File.join(LIBHEGEL_DIR, libhegel_asset_name)

file LIBHEGEL_PATH do |task|
  asset = File.basename(task.name)
  Dir.mktmpdir do |staging|
    sh "gh", "release", "download", "v#{LIBHEGEL_VERSION}",
      "--repo", "hegeldev/hegel-rust",
      "--pattern", asset, "--pattern", "#{asset}.sha256",
      "--dir", staging

    expected = File.read(File.join(staging, "#{asset}.sha256")).split.first
    actual = Digest::SHA256.hexdigest(File.binread(File.join(staging, asset)))
    raise "SHA-256 mismatch for #{asset}: expected #{expected}, got #{actual}" unless actual == expected

    FileUtils.mkdir_p(LIBHEGEL_DIR)
    FileUtils.mv(File.join(staging, asset), task.name)
  end
end

# Keep the rake invocation self-contained: the engine resolves through
# HEGEL_LIBHEGEL_PATH when direnv has loaded .envrc, and through the staged
# copy otherwise.
ENV["HEGEL_LIBHEGEL_PATH"] = LIBHEGEL_DIR if ENV["HEGEL_LIBHEGEL_PATH"].nil? || ENV["HEGEL_LIBHEGEL_PATH"].empty?

task test: LIBHEGEL_PATH

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
