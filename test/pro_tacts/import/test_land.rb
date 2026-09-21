require_relative "../../test_helper"

require "pro_tacts/import/land"
require "pro_tacts/import/vcf"

# Landing the cards an import has settled on
# (docs/plans/2026-09-21-import-a-vcf.md).
class ImportLandTest < Minitest::Test
  include ThrowawayContacts

  Land = ProTacts::Import::Land
  Vcf = ProTacts::Import::Vcf

  JANE = <<~CARD.gsub("\n", "\r\n")
    BEGIN:VCARD
    VERSION:3.0
    N:Booles;Jane;;;
    FN:Jane Booles
    NOTE:Met at work
    UID:ABC-123
    END:VCARD
  CARD

  def land(cards: Vcf.cards(JANE), group: nil)
    with_contacts({}) do |store|
      yield Land.call(store, cards, group:), store
    end
  end

  # What arrives here is already what is coming in, so nothing is
  # pared, rewritten or rebuilt but the card's identity.
  def test_the_card_lands_as_it_was_handed_over
    land do |landed, _store|
      card = landed.fetch(0).vcard.to_s

      assert_includes card, "N:Booles;Jane;;;\r\n"
      assert_includes card, "FN:Jane Booles\r\n"
      assert_includes card, "NOTE:Met at work\r\n"
    end
  end

  # A minted id, and the UID spelling it: the source's own UID named a
  # record in a book this is not (rake contacts:reid's whole subject).
  def test_the_card_lands_under_a_minted_id_its_uid_spells
    land do |landed, store|
      id = landed.fetch(0).id

      assert ProTacts::ChangeId.minted?(id)
      refute_includes landed.fetch(0).vcard.to_s, "ABC-123"
      assert_includes landed.fetch(0).vcard.to_s, "UID:#{id}\r\n"
      assert_equal id, store.card_id_with_uid(id)
    end
  end

  # A card this creates joins everyone's book the way a client's
  # create does, and the import's own group besides.
  def test_arrivals_join_the_import_group_and_everyones_book
    land(cards: Vcf.cards(JANE + JANE), group: "import-20260921T031655Z") do |landed, store|
      ids = landed.map(&:id)

      assert_equal 2, ids.uniq.length
      groups = store.all_groups.select { it.members.sort == ids.sort }

      assert_equal ["import-20260921T031655Z", ProTacts::Store::EVERYONE],
                   groups.map(&:name).sort
    end
  end

  # The group is looked up before it is made, and the first card's put
  # is what creates `sync:*` — so a list read once up front would send
  # the next lookup to create a group that now exists
  # (db/migrations/008_group_names.rb).
  def test_landing_into_a_group_that_already_exists_joins_it
    with_contacts({}) do |store|
      existing = store.create_group(name: "import-20260921T031655Z")

      landed = Land.call(store, Vcf.cards(JANE + JANE), group: "import-20260921T031655Z")

      assert_equal landed.map(&:id).sort, store.group(existing).members.sort
      assert_equal 1, store.all_groups.count { it.name == "import-20260921T031655Z" }
    end
  end

  # The groups the review screen ticked, joined alongside the name it
  # typed: an import is as often "these are the people from the school
  # list" as it is a batch that only needs finding again.
  def test_arrivals_join_the_groups_the_review_chose
    with_contacts({}) do |store|
      school = store.create_group(name: "school")

      landed = Land.call(store, Vcf.cards(JANE), group: "import-20260921T031655Z", join: [school])
      id = landed.fetch(0).id

      assert_equal [id], store.group(school).members
      assert_equal ["import-20260921T031655Z", "school", ProTacts::Store::EVERYONE],
                   store.all_groups.select { it.members.include?(id) }.map(&:name).sort
    end
  end

  # Either, or neither: the chosen groups stand on their own when no
  # name is typed.
  def test_arrivals_join_a_chosen_group_with_no_group_named
    with_contacts({}) do |store|
      school = store.create_group(name: "school")

      landed = Land.call(store, Vcf.cards(JANE), join: [school])

      assert_equal landed.map(&:id), store.group(school).members
      assert_equal %w[school], store.all_groups.map(&:name).reject { it == ProTacts::Store::EVERYONE }
    end
  end

  def test_no_group_name_lands_the_cards_in_everyones_book_alone
    land do |landed, store|
      assert_equal [ProTacts::Store::EVERYONE], store.all_groups.map(&:name)
      assert_equal landed.map(&:id), store.all_groups.fetch(0).members
    end
  end

  # Named for when it happened, so what landed together can be found
  # together.
  def test_the_default_group_is_named_for_the_moment
    assert_equal "import-20260921T031655Z", Land.default_group(Time.utc(2026, 9, 21, 3, 16, 55))
  end
end
