# The demo entrypoint: the fixture book, and a login written the way the
# proxy would write it. Both the dev server (dev.ru, which adds what
# marks a dev run) and the preview app (fly.preview.toml, which runs this
# file) serve from here, so the two differ in their branding and nothing
# else. A deployment runs config.ru, which has neither the seed nor the
# login and reads no flag that would turn them on.
require "pathname"

$LOAD_PATH.unshift(Pathname.new(__dir__) / "lib")
require "pro_tacts"
require "pro_tacts/stub_login"
require_relative "test/fixture_data"

config = ProTacts.config

# Seeded when there is no database yet, not on every boot: a fresh data
# directory gets the fixture book, and a restart keeps whatever has been
# done to it since (an entr reload in dev, a machine coming back in
# preview). A fresh `rake dev` is a new tmpdir and a new deploy is a new
# image, so either is what resets to the fixtures. FixtureData.install
# rebuilds the directory it is handed, which is why it is asked only
# once and only where the database it names is missing (this is the one
# entrypoint that never runs against a deployment's data, and it leaves
# PRO_TACTS_DATABASE alone so the two paths agree).
unless config.database_path.exist?
  store = FixtureData.install(config.data_dir)
  # The book the stand-in login syncs; `rake dev` named it here before
  # the preview wanted the same book.
  store.name_book(ProTacts::StubLogin::LOGIN, "alpha")
  store.close
end

use ProTacts::StubLogin
run Rack::Builder.parse_file(File.expand_path("config.ru", __dir__))
