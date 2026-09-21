require_relative "../../test_helper"

require "pro_tacts/import/write"
require "pro_tacts/import/vcf"

# Writing the cards an import has settled on
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

  def write_cards(cards: Vcf.cards(JANE), group: nil)
    with_contacts({}) do |store|
      yield Write.call(store, cards, group:), store
    end
  end

  # What arrives here is already what is coming in, so nothing is
  # pared, rewritten or rebuilt but the card's identity.
  def test_the_card_comes_in_as_it_was_handed_over
    write_cards do |imported, _store|
      card = imported.fetch(0).vcard.to_s

      assert_includes card, "N:Booles;Jane;;;\r\n"
      assert_includes card, "FN:Jane Booles\r\n"
      assert_includes card, "NOTE:Met at work\r\n"
    end
  end

  # A minted id, and the UID spelling it: the source's own UID named a
  # record in a book this is not (rake contacts:reid's whole subject).
  def test_the_card_is_stored_under_a_minted_id_its_uid_spells
    write_cards do |imported, store|
      id = imported.fetch(0).id

      assert ProTacts::ChangeId.minted?(id)
      refute_includes imported.fetch(0).vcard.to_s, "ABC-123"
      assert_includes imported.fetch(0).vcard.to_s, "UID:#{id}\r\n"
      assert_equal id, store.card_id_with_uid(id)
    end
  end

  # A card this creates joins everyone's book the way a client's
  # create does, and the import's own group besides.
  def test_arrivals_join_the_import_group_and_everyones_book
    write_cards(cards: Vcf.cards(JANE + JANE), group: "import-20260921T031655Z") do |imported, store|
      ids = imported.map(&:id)

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

      imported = Write.call(store, Vcf.cards(JANE + JANE), group: "import-20260921T031655Z")

      assert_equal imported.map(&:id).sort, store.group(existing).members.sort
      assert_equal 1, store.all_groups.count { it.name == "import-20260921T031655Z" }
    end
  end

  # The groups the walk ticked, joined alongside the name the review
  # screen typed: the import's own group takes in everything, and the
  # rest is a contact at a time.
  def test_an_arrival_joins_the_groups_chosen_for_it
    with_contacts({}) do |store|
      school = store.create_group(name: "school")

      imported = Write.call(store, Vcf.cards(JANE), group: "import-20260921T031655Z", joins: [[school]])
      id = imported.fetch(0).id

      assert_equal [id], store.group(school).members
      assert_equal ["import-20260921T031655Z", "school", ProTacts::Store::EVERYONE],
                   store.all_groups.select { it.members.include?(id) }.map(&:name).sort
    end
  end

  # A contact at a time means the cards do not all come in alike: the
  # choices are read by the card's own place in the file.
  def test_each_arrival_joins_its_own_groups
    with_contacts({}) do |store|
      school = store.create_group(name: "school")
      work = store.create_group(name: "work")

      imported = Write.call(store, Vcf.cards(JANE + JANE + JANE), joins: [[school], [], [work, school]])
      first, second, third = imported.map(&:id)

      assert_equal [first, third].sort, store.group(school).members.sort
      assert_equal [third], store.group(work).members
      assert_equal [ProTacts::Store::EVERYONE],
                   store.all_groups.select { it.members.include?(second) }.map(&:name)
    end
  end

  # A group the walk asked for by name is made here and not before:
  # a group created while the walk was still going is one left behind
  # by an import that was abandoned.
  def test_a_group_named_during_the_walk_is_made_at_the_confirm
    with_contacts({}) do |store|
      imported = Write.call(store, Vcf.cards(JANE + JANE), named: [["Clarks"], ["Clarks"]])
      clarks = store.all_groups.find { it.name == "Clarks" }

      assert_equal imported.map(&:id).sort, clarks.members.sort
      assert_equal 1, store.all_groups.count { it.name == "Clarks" }
    end
  end

  # Two answers can mean one group, and a membership written twice is
  # a constraint violation rather than a second membership.
  def test_a_name_that_is_the_imports_own_group_joins_it_once
    with_contacts({}) do |store|
      imported = Write.call(store, Vcf.cards(JANE), group: "Clarks", named: [["Clarks"]])
      id = imported.fetch(0).id

      assert_equal 1, store.all_groups.count { it.name == "Clarks" }
      assert_equal [id], store.all_groups.find { it.name == "Clarks" }.members
    end
  end

  # Either, or neither: a chosen group stands on its own when no name
  # is typed.
  def test_arrivals_join_a_chosen_group_with_no_group_named
    with_contacts({}) do |store|
      school = store.create_group(name: "school")

      imported = Write.call(store, Vcf.cards(JANE), joins: [[school]])

      assert_equal imported.map(&:id), store.group(school).members
      assert_equal %w[school], store.all_groups.map(&:name).reject { it == ProTacts::Store::EVERYONE }
    end
  end

  def test_no_group_name_puts_the_cards_in_everyones_book_alone
    write_cards do |imported, store|
      assert_equal [ProTacts::Store::EVERYONE], store.all_groups.map(&:name)
      assert_equal imported.map(&:id), store.all_groups.fetch(0).members
    end
  end

  # Named for when it happened, so what imported together can be found
  # together.
  def test_the_default_group_is_named_for_the_moment
    assert_equal "import-20260921T031655Z", Write.default_group(Time.utc(2026, 9, 21, 3, 16, 55))
  end
end
