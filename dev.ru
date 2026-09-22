# config.ru for `rake dev`: the demo entrypoint (demo.ru, which seeds the
# fixture book and writes the login) plus what marks a dev run. The
# preview app runs demo.ru with its own branding; deployments run
# config.ru alone.
require "pathname"

$LOAD_PATH.unshift(Pathname.new(__dir__) / "lib")
require "pro_tacts"

# The change being worked on names a dev build, the way a release's tag
# names an image; a change id holds still while its content is edited.
change = `jj log --no-graph -r @ -T 'change_id.short()'`
fail "jj could not name the working-copy change" unless $?.success?

# What marks a dev run, set before demo.ru and config.ru read the config.
# An exported variable still wins over each.
ProTacts.config = ProTacts::Config.new({
  "PRO_TACTS_INSTANCE_NAME" => "pro-tacts (dev)",
  "PRO_TACTS_FAVICON" => "/favicon-dev.svg",
  "PRO_TACTS_ACCENT" => "ink-blue",
  "VERSION" => change,
}.merge(ENV))

run Rack::Builder.parse_file(File.expand_path("demo.ru", __dir__))
