
# Stages the native libhegel engine that the hegeltest gem drives — the
# gem is pre-release and bundles no binary yet. Once it ships a real gem
# with a bundled engine, delete this file and the tasks/ import line in
# the Rakefile and this all goes away.
#
# The engine version comes from the gem (Hegel::LIBHEGEL_VERSION) because
# the binding targets a specific engine ABI. The asset is downloaded with
# gh (which handles the release-asset redirects), verified against its
# published SHA-256, and installed under tmp/libhegel/<version>/ (see
# .gitignore). HEGEL_LIBHEGEL_PATH in .envrc points at that directory, so
# whichever platform's asset landed there resolves.

require "digest"
require "pathname"
require "rbconfig"
require "fileutils"
require "tmpdir"
require "hegel/libhegel_version"

LIBHEGEL_VERSION = Hegel::LIBHEGEL_VERSION
LIBHEGEL_ASSETS = {
  "arm64-darwin" => "libhegel-darwin-arm64.dylib",
  "aarch64-linux" => "libhegel-linux-arm64.so",
  "x86_64-linux" => "libhegel-linux-amd64.so",
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

LIBHEGEL_DIR = Pathname.new(__dir__).parent / "tmp" / "libhegel" / LIBHEGEL_VERSION
LIBHEGEL_PATH = LIBHEGEL_DIR / libhegel_asset_name

file LIBHEGEL_PATH do |task|
  asset = Pathname.new(task.name).basename.to_s
  Dir.mktmpdir do |dir|
    staging = Pathname.new(dir)
    sh "gh", "release", "download", "v#{LIBHEGEL_VERSION}",
      "--repo", "hegeldev/hegel-rust",
      "--pattern", asset, "--pattern", "#{asset}.sha256",
      "--dir", dir, verbose: false

    expected = File.read(staging / "#{asset}.sha256").split.first
    actual = Digest::SHA256.hexdigest(File.binread(staging / asset))
    raise "SHA-256 mismatch for #{asset}: expected #{expected}, got #{actual}" unless actual == expected

    FileUtils.mkdir_p(LIBHEGEL_DIR)
    FileUtils.mv(staging / asset, task.name)
  end
end

# Keep a bare `rake test` self-contained: the engine resolves through
# HEGEL_LIBHEGEL_PATH when direnv has loaded .envrc, and through the
# staged copy otherwise.
ENV["HEGEL_LIBHEGEL_PATH"] = LIBHEGEL_DIR.to_s if ENV.fetch("HEGEL_LIBHEGEL_PATH", "").empty?

task test: LIBHEGEL_PATH
