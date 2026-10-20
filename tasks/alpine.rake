# Alpine (https://alpinejs.dev) is the admin UI's only script, and it
# is vendored for the reason the Gloss CSS is: this app is reachable
# only through `tailscale serve`, and a page that needs a CDN reachable
# to work is a page that stops working for a reason nothing here
# controls. The version below is the pin — this task is how it moves.
# The official plugins it vendors beside the core are released with it,
# so one version pins them all.

ALPINE_VERSION = "3.17.1"

# Each file under public/vendor/alpine, and the npm package it is.
# Resize is x-resize, which the birthday row's month select reads its
# width through (Admin::ContactsEdit#birthday_controls).
ALPINE_PACKAGES = {"alpine" => "alpinejs", "resize" => "@alpinejs/resize"}.freeze

namespace :alpine do
  desc "Refresh the vendored Alpine and its plugins from npm (ALPINE=version, default #{ALPINE_VERSION})"
  task :vendor do
    require "fileutils"
    require "pathname"

    version = ENV.fetch("ALPINE", ALPINE_VERSION)
    out = Pathname.new(__dir__).parent / "public" / "vendor" / "alpine"
    FileUtils.mkdir_p(out)

    ALPINE_PACKAGES.each do |file, package|
      url = "https://cdn.jsdelivr.net/npm/#{package}@#{version}/dist/cdn.min.js"

      body = `curl -fsS --max-time 60 #{url}`
      abort "could not fetch #{url}" unless $?.success?

      # The banner is the only record of which build this is: the file
      # itself is minified and says nothing about its own version.
      header = "/* #{package} #{version}, vendored from #{url} on " \
               "#{Time.now.utc.strftime("%Y-%m-%d")}. Refresh with `rake alpine:vendor`; " \
               "bump ALPINE_VERSION in tasks/alpine.rake to move the pin. */\n"

      (out / "#{file}.min.js").write(header + body)
      puts "wrote #{out / "#{file}.min.js"} (#{body.bytesize} bytes)"
    end
  end
end
