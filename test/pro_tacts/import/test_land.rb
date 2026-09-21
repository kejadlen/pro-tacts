require_relative "../../test_helper"

require "pro_tacts/import/land"
require "pro_tacts/import/vcf"

# Landing an uploaded .vcf's cards, with the importer's decisions
# spent on the way in (docs/plans/2026-09-21-import-a-vcf.md).
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
    item1.X-ABRELATEDNAMES:Sam Booles
    item1.X-ABLabel:_$!<Spouse>!$_
    X-SOCIALPROFILE;type=twitter:https://twitter.com/jb
    UID:ABC-123
    END:VCARD
  CARD

  def land(decisions, cards: Vcf.cards(JANE), group: nil)
    with_contacts({}) do |store|
      landed = Land.call(store, cards, decisions:, group:)
      yield landed, store
    end
  end

  # Nothing rebuilds a card out of fields: the bytes that arrived are
  # the bytes that are stored, minus the id this server gives it.
  def test_a_kept_property_travels_with_the_card
    land({"X-SOCIALPROFILE" => Vcf::KEEP}) do |landed, _store|
      card = landed.fetch(0).vcard.to_s

      assert_includes card, "X-SOCIALPROFILE;type=twitter:https://twitter.com/jb\r\n"
      assert_includes card, "item1.X-ABRELATEDNAMES:Sam Booles\r\n"
    end
  end

  # A property nobody was asked about is kept, which is every known
  # one and any unknown one the form said nothing about.
  def test_a_property_nobody_decided_is_kept
    land({}) do |landed, _store|
      assert_includes landed.fetch(0).vcard.to_s, "X-SOCIALPROFILE"
    end
  end

  def test_a_dropped_property_is_gone
    land({"X-SOCIALPROFILE" => Vcf::DROP}) do |landed, _store|
      card = landed.fetch(0).vcard.to_s

      refute_includes card, "X-SOCIALPROFILE"
      assert_includes card, "FN:Jane Booles\r\n"
    end
  end

  # Apple hangs a row's label off the line it names rather than inside
  # it, so a label whose line is dropped would be left naming nothing.
  def test_a_dropped_line_takes_its_label_with_it
    land({"X-ABRELATEDNAMES" => Vcf::DROP}) do |landed, _store|
      card = landed.fetch(0).vcard.to_s

      refute_includes card, "X-ABRELATEDNAMES"
      refute_includes card, "X-ABLabel"
    end
  end

  # The note is where a value goes when it is worth reading and there
  # is no field to read it in. It is called what the row was called,
  # not what the property was named.
  def test_a_noted_property_is_written_under_the_note_by_its_label
    land({"X-ABRELATEDNAMES" => Vcf::NOTE}) do |landed, _store|
      card = landed.fetch(0).vcard.to_s

      refute_includes card, "X-ABRELATEDNAMES"
      refute_includes card, "X-ABLabel"
      # One NOTE, the card's own and the addition, joined by the
      # escape a line break inside a text value is written as.
      assert_includes card, "NOTE:Met at work\\nSpouse: Sam Booles\r\n"
      assert_equal 1, card.scan("NOTE:").length
    end
  end

  def test_a_noted_property_with_no_label_is_written_under_its_own_name
    land({"X-SOCIALPROFILE" => Vcf::NOTE}) do |landed, _store|
      assert_includes landed.fetch(0).vcard.to_s,
                      "NOTE:Met at work\\nX-SOCIALPROFILE: https://twitter.com/jb\r\n"
    end
  end

  def test_a_card_with_no_note_gets_one
    cards = Vcf.cards(JANE.sub("NOTE:Met at work\r\n", ""))

    land({"X-ABRELATEDNAMES" => Vcf::NOTE}, cards:) do |landed, _store|
      assert_includes landed.fetch(0).vcard.to_s, "NOTE:Spouse: Sam Booles\r\n"
    end
  end

  # A minted id, and the UID spelling it: the source's own UID named a
  # record in a book this is not (rake contacts:reid's whole subject).
  def test_the_card_lands_under_a_minted_id_its_uid_spells
    land({}) do |landed, store|
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
    land({}, cards: Vcf.cards(JANE + JANE), group: "import-20260921T031655Z") do |landed, store|
      ids = landed.map(&:id)

      assert_equal 2, ids.uniq.length
      groups = store.all_groups.select { it.members.sort == ids.sort }

      assert_equal [ProTacts::Store::EVERYONE, "import-20260921T031655Z"],
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

      landed = Land.call(store, Vcf.cards(JANE + JANE), decisions: {}, group: "import-20260921T031655Z")

      assert_equal landed.map(&:id).sort, store.group(existing).members.sort
      assert_equal 1, store.all_groups.count { it.name == "import-20260921T031655Z" }
    end
  end

  def test_no_group_name_lands_the_cards_in_everyones_book_alone
    land({}) do |landed, store|
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
