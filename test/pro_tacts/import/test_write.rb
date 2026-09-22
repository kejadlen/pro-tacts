require_relative "../../test_helper"

require "pro_tacts/import/write"
require "pro_tacts/import/vcf"

# Writing a card an import has settled on
# (docs/plans/2026-09-21-import-a-vcf.md).
class ImportWriteTest < Minitest::Test
  include ThrowawayContacts

  Write = ProTacts::Import::Write
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

  # One card, which is what one Save hands over.
  def card = Vcf.cards(JANE).fetch(0)

  def write_card(group: nil, joins: [], named: [])
    with_contacts({}) do |store|
      yield Write.call(store, card, group:, joins:, named:), store
    end
  end

  # What arrives here is already what is coming in, so nothing is
  # pared, rewritten or rebuilt but the card's identity.
  def test_the_card_comes_in_as_it_was_handed_over
    write_card do |imported, _store|
      written = imported.vcard.to_s

      assert_includes written, "N:Booles;Jane;;;\r\n"
      assert_includes written, "FN:Jane Booles\r\n"
      assert_includes written, "NOTE:Met at work\r\n"
    end
  end

  # A minted id, and the UID spelling it: the source's own UID named a
  # record in a book this is not (rake contacts:reid's whole subject).
  def test_the_card_is_stored_under_a_minted_id_its_uid_spells
    write_card do |imported, store|
      id = imported.id

      assert ProTacts::ChangeId.minted?(id)
      refute_includes imported.vcard.to_s, "ABC-123"
      assert_includes imported.vcard.to_s, "UID:#{id}\r\n"
      assert_equal id, store.card_id_with_uid(id)
    end
  end

  # A card this creates joins everyone's book the way a client's
  # create does, and the import's own group besides. One call per
  # card, so the second card's group is the first card's, found
  # rather than made again.
  def test_arrivals_join_the_import_group_and_everyones_book
    with_contacts({}) do |store|
      ids = 2.times.map { Write.call(store, card, group: "import-20260921T031655Z").id }

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
  def test_writing_into_a_group_that_already_exists_joins_it
    with_contacts({}) do |store|
      existing = store.create_group(name: "import-20260921T031655Z")

      ids = 2.times.map { Write.call(store, card, group: "import-20260921T031655Z").id }

      assert_equal ids.sort, store.group(existing).members.sort
      assert_equal 1, store.all_groups.count { it.name == "import-20260921T031655Z" }
    end
  end

  # The groups the walk ticked beside this card, joined alongside the
  # group the import files everything under.
  def test_an_arrival_joins_the_groups_chosen_for_it
    with_contacts({}) do |store|
      school = store.create_group(name: "school")

      id = Write.call(store, card, group: "import-20260921T031655Z", joins: [school]).id

      assert_equal [id], store.group(school).members
      assert_equal ["import-20260921T031655Z", "school", ProTacts::Store::EVERYONE],
                   store.all_groups.select { it.members.include?(id) }.map(&:name).sort
    end
  end

  # A card at a time means the cards do not all come in alike: each
  # call carries the answer its own screen gave.
  def test_each_arrival_joins_its_own_groups
    with_contacts({}) do |store|
      school = store.create_group(name: "school")
      work = store.create_group(name: "work")

      first = Write.call(store, card, joins: [school]).id
      second = Write.call(store, card).id
      third = Write.call(store, card, joins: [work, school]).id

      assert_equal [first, third].sort, store.group(school).members.sort
      assert_equal [third], store.group(work).members
      assert_equal [ProTacts::Store::EVERYONE],
                   store.all_groups.select { it.members.include?(second) }.map(&:name)
    end
  end

  # A group the walk asked for by name is made with the contact it was
  # named for, and found by the next card that asks for it: a group
  # created before the card is saved is one left behind if that card
  # never is.
  def test_a_group_named_during_the_walk_is_made_with_its_contact
    with_contacts({}) do |store|
      ids = 2.times.map { Write.call(store, card, named: ["Clarks"]).id }
      clarks = store.all_groups.find { it.name == "Clarks" }

      assert_equal ids.sort, clarks.members.sort
      assert_equal 1, store.all_groups.count { it.name == "Clarks" }
    end
  end

  # Two answers can mean one group, and a membership written twice is
  # a constraint violation rather than a second membership.
  def test_a_name_that_is_the_imports_own_group_joins_it_once
    with_contacts({}) do |store|
      id = Write.call(store, card, group: "Clarks", named: ["Clarks"]).id

      assert_equal 1, store.all_groups.count { it.name == "Clarks" }
      assert_equal [id], store.all_groups.find { it.name == "Clarks" }.members
    end
  end

  # Either, or neither: a chosen group stands on its own when the
  # import files under no group at all.
  def test_arrivals_join_a_chosen_group_with_no_group_named
    with_contacts({}) do |store|
      school = store.create_group(name: "school")

      id = Write.call(store, card, joins: [school]).id

      assert_equal [id], store.group(school).members
      assert_equal %w[school], store.all_groups.map(&:name).reject { it == ProTacts::Store::EVERYONE }
    end
  end

  def test_no_group_name_puts_the_card_in_everyones_book_alone
    write_card do |imported, store|
      assert_equal [ProTacts::Store::EVERYONE], store.all_groups.map(&:name)
      assert_equal [imported.id], store.all_groups.fetch(0).members
    end
  end

  # Named for when it happened, so what imported together can be found
  # together.
  def test_the_default_group_is_named_for_the_moment
    assert_equal "import-20260921T031655Z", Write.default_group(Time.utc(2026, 9, 21, 3, 16, 55))
  end
end
