# Alpine (https://alpinejs.dev) is the admin UI's only script, and it
# is vendored for the reason the Gloss CSS is: this app is reachable
# only through `tailscale serve`, and a page that needs a CDN reachable
# to work is a page that stops working for a reason nothing here
# controls. The version below is the pin — this task is how it moves.

ALPINE_VERSION = "3.17.1"

namespace :alpine do
  desc "Refresh the vendored Alpine from npm (ALPINE=version, default #{ALPINE_VERSION})"
  task :vendor do
    require "fileutils"
    require "pathname"

    version = ENV.fetch("ALPINE", ALPINE_VERSION)
    url = "https://cdn.jsdelivr.net/npm/alpinejs@#{version}/dist/cdn.min.js"

    body = `curl -fsS --max-time 60 #{url}`
    abort "could not fetch #{url}" unless $?.success?

    out = Pathname.new(__dir__).parent / "public" / "vendor" / "alpine"
    FileUtils.mkdir_p(out)

    # The banner is the only record of which build this is: the file
    # itself is minified and says nothing about its own version.
    header = "/* Alpine #{version}, vendored from #{url} on " \
             "#{Time.now.utc.strftime("%Y-%m-%d")}. Refresh with `rake alpine:vendor`; " \
             "bump ALPINE_VERSION in tasks/alpine.rake to move the pin. */\n"

    (out / "alpine.min.js").write(header + body)
    puts "wrote #{out / "alpine.min.js"} (#{body.bytesize} bytes)"
  end
end
