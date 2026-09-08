
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

  # The first card is stamped now and each one after it is #SPREAD times
  # older than the last, so the seed book runs from this minute out to
  # about five years at nineteen cards. Computed rather than tabulated
  # because a table runs out: adding cards past the end of one either
  # wraps — two cards sharing a stamp, and a recently-updated list that
  # opens on a tie — or leaves the tail unstamped. Spread rather than
  # exact: what backdate wants is variety for the admin UI's
  # recently-updated list, not specific values for anything to assert on.
  SPREAD = 2.4

  #: (Integer index) -> Integer
  def self.ago_seconds(index)
    index.zero? ? 0 : (60 * SPREAD**(index - 1)).round
  end

  # Every seed card, keyed by the id its filename gives it.
  def self.cards
    CARDS.glob("*.vcf").sort.to_h { [it.basename(".vcf").to_s, it.read] }
  end

  # What the household shares: an address and a note, which is both
  # what a group may hold (see db/migrations/004_groups.rb) and the
  # shape the groups work tests against
  # (docs/plans/2026-08-24-vcard-storage-and-groups.md). Deliberately
  # not the address any seed card already carries, so a test can tell
  # a composed line from a stored one by its bytes.
  HOUSEHOLD = [
    "ADR;TYPE=home:;;7 Calculus Close;London;England;NW1 1AB;United Kingdom",
    "NOTE:Gate code 1854. The dog is friendly\\, the goose is not.",
  ].freeze #: Array[String]

  # The groups the fixture book carries. The first is a household, the
  # three household-* cards in it. Those cards are a family — one
  # surname, a mobile and an email each, and no address or note of
  # their own — so everything the admin UI shows on them in those two
  # rows is the group's, and removing a member visibly takes it away.
  # They sit outside the recorded macOS exchange's hrefs, so the replay
  # keeps serving that session the bytes it saw.
  #
  # The second is the nameless case: every bday-* card in one group
  # with no name and nothing to lend
  # (db/migrations/005_group_identity.rb). It moves no member's bytes —
  # a group that holds nothing composes nothing, so the replay is
  # untouched by it — and what it is here for is the surfaces that show
  # a group rather than a card, which have a group with no name to
  # render as its id (docs/DESIGN.md, "Groups are first-class
  # records").
  #
  # Seeded in Ruby rather than a fixture file because the cards are the
  # only evidence-shaped fixtures — a group is rows across three
  # tables with no file format of its own. The group itself is
  # Store#create_group's, which mints the id no caller gets to choose;
  # its properties and members have no write path yet — authoring is
  # the admin UI's task — so those rows land the way backdate's do,
  # through the store's own database.
  MEMBERS = %w[household-george household-mary household-alicia].freeze #: Array[String]

  # The seed's birthday shapes, read off the card ids rather than
  # listed again, so a shape added to test/fixtures/cards joins the
  # group by being named like its neighbours.
  #: () -> Array[String]
  def self.birthday_cards
    cards.keys.grep(/\Abday-/)
  end

  #: (ProTacts::Store store) -> void
  def self.seed_groups(store)
    database = store.instance_variable_get(:@database)

    household = store.create_group(name: "Booles")
    HOUSEHOLD.each.with_index do |line, position|
      database[:group_properties].insert(group_id: household, position:, line:)
    end
    MEMBERS.each do |id|
      database[:group_members].insert(group_id: household, card_id: id)
    end

    birthdays = store.create_group
    birthday_cards.each do |id|
      database[:group_members].insert(group_id: birthdays, card_id: id)
    end
  end

  # Builds the database and returns a store still open on it, for the
  # caller to hand to the app the way config.ru does.
  def self.install(directory)
    directory = Pathname.new(directory)
    FileUtils.rm_rf(directory)
    FileUtils.mkdir_p(directory)

    store = ProTacts::Store.at(directory / "contacts.db")
    seed = cards
    seed.each do |id, card|
      store.put(id, card)
    end
    backdate(store, seed.keys)
    seed_groups(store)
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
      stamp = (now - ago_seconds(index)).strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
      database[:cards].where(id:).update(updated_at: stamp)
    end
  end
end
