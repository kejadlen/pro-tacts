
require "fileutils"
require "pathname"

require "pro_tacts/store"

# Builds the data directory the tests and `rake fixtures` run against: a
# database seeded from the cards in test/fixtures/cards, rebuilt from
# scratch every time so a replay never depends on what a previous run
# left behind.
#
# The cards are files rather than a checked-in database because they are
# evidence, the same standing the request files in macos-exchange have:
# a reviewer can read a .vcf and a diff means something. The database is
# derived from them, and lives in a throwaway tmpdir with everything
# else that does.
module FixtureData
  CARDS = Pathname.new(__dir__) / "fixtures" / "cards"

  # How long ago each successive card (in #cards' own order) last
  # changed, cycling if there are ever more cards than entries. Spread
  # rather than exact: what backdate wants is variety for the admin
  # UI's recently-updated list, not specific values for anything to
  # assert on.
  AGO_SECONDS = [
    0, 3 * 60, 20 * 60, 90 * 60,
    4 * 3_600, 18 * 3_600,
    2 * 86_400, 5 * 86_400, 12 * 86_400, 26 * 86_400,
    60 * 86_400, 130 * 86_400, 260 * 86_400, 380 * 86_400,
  ].freeze

  # Every seed card, keyed by the id its filename gives it.
  def self.cards
    CARDS.glob("*.vcf").sort.to_h { [it.basename(".vcf").to_s, it.read] }
  end

  # Builds the database and returns a store still open on it, for the
  # caller to hand to the app the way config.ru does.
  def self.install(directory)
    directory = Pathname.new(directory)
    FileUtils.rm_rf(directory)
    FileUtils.mkdir_p(directory)

    store = ProTacts::Store.at(directory / "contacts.db")
    ids = cards.each do |id, card|
      store.put(id, card)
    end.keys
    backdate(store, ids)
    store
  end

  # Store#put always asks SQLite for the current time (see the comment
  # on ProTacts::Store::NOW) — on purpose, since a real write's stamp
  # has to be the database's clock, not Ruby's idea of one. A fixture
  # book installed in one quick burst would otherwise land every card
  # within the same millisecond, and "recently updated" would show
  # nothing else. Fixture data is synthetic by definition, so backdating
  # it here is not the write path that invariant protects — reached the
  # same way a test does, through the store's own database (see
  # StoreTest#database in test/pro_tacts/test_store.rb), because nothing
  # public exposes it and nothing public should.
  def self.backdate(store, ids)
    database = store.instance_variable_get(:@database)
    now = Time.now.utc
    ids.each_with_index do |id, index|
      ago = AGO_SECONDS.fetch(index % AGO_SECONDS.length)
      stamp = (now - ago).strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
      database[:cards].where(id:).update(updated_at: stamp)
    end
  end
end
