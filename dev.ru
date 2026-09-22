# config.ru for `rake dev`, which has no proxy in front of it to write
# the login (ProTacts::StubLogin). Deployments run config.ru alone; the
# preview one reaches the same middleware through PRO_TACTS_DEFAULT_LOGIN.
require "pathname"

$LOAD_PATH.unshift(Pathname.new(__dir__) / "lib")
require "pro_tacts"
require "pro_tacts/stub_login"

# The change being worked on names a dev build, the way a release's tag
# names an image; a change id holds still while its content is edited.
change = `jj log --no-graph -r @ -T 'change_id.short()'`
fail "jj could not name the working-copy change" unless $?.success?

# What marks a dev run, set before config.ru reads the config. An
# exported variable still wins over each.
ProTacts.config = ProTacts::Config.new({
  "PRO_TACTS_INSTANCE_NAME" => "pro-tacts (dev)",
  "PRO_TACTS_FAVICON" => "/favicon-dev.svg",
  "PRO_TACTS_ACCENT" => "ink-blue",
  "VERSION" => change,
}.merge(ENV))

use ProTacts::StubLogin
run Rack::Builder.parse_file(File.expand_path("config.ru", __dir__))
