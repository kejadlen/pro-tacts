
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
# derived from them, and lives under tmp/ with everything else that is.
module FixtureData
  CARDS = Pathname.new(__dir__) / "fixtures" / "cards"

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
    cards.each do |id, card|
      store.put(id, card)
    end
    store
  end
end
