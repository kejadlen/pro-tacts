# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "digest"
require "net/http"
require "rbconfig"
require "fileutils"

require "minitest/test_task"

Minitest::TestTask.create

# The hegeltest gem drives a native libhegel engine that ships separately
# (the gem is pre-release and bundles no binary yet). This task stages it
# for the host platform, mirroring hegel-ruby's own libhegel:fetch: pinned
# release asset from hegeldev/hegel-rust, verified against its published
# SHA-256, installed under tmp/libhegel/<version>/ (gitignored). The
# directory form of HEGEL_LIBHEGEL_PATH in .envrc resolves whichever
# platform's asset landed there.
LIBHEGEL_VERSION = "0.32.5"
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

# Minimal redirect-following GET: GitHub release assets 302 to a CDN.
def http_get(uri, limit = 5)
  raise "too many redirects" if limit.zero?

  response = Net::HTTP.get_response(URI(uri))
  case response
  when Net::HTTPRedirection then http_get(response["location"], limit - 1)
  when Net::HTTPSuccess then response.body
  else raise "GET #{uri}: #{response.code} #{response.message}"
  end
end

def download_libhegel(path)
  base = "https://github.com/hegeldev/hegel-rust/releases/download/v#{LIBHEGEL_VERSION}"
  asset = File.basename(path)
  bytes = http_get("#{base}/#{asset}")
  expected = http_get("#{base}/#{asset}.sha256").split.first
  actual = Digest::SHA256.hexdigest(bytes)
  raise "SHA-256 mismatch for #{asset}: expected #{expected}, got #{actual}" unless actual == expected

  FileUtils.mkdir_p(File.dirname(path))
  tmp = "#{path}.#{Process.pid}.partial"
  File.binwrite(tmp, bytes)
  File.rename(tmp, path)
end

file LIBHEGEL_PATH do |task|
  download_libhegel(task.name)
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
