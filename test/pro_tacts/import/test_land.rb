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
    item1.ADR;type=HOME:;;1 Main St;Springfield;;;
    item1.X-ABLabel:_$!<Home>!$_
    item2.X-ABRELATEDNAMES:Sam Booles
    item2.X-ABLabel:_$!<Spouse>!$_
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

  # Nothing rebuilds a card out of fields: every line this book reads
  # is the bytes that arrived, minus the id this server gives it.
  def test_what_this_book_reads_travels_with_the_card
    land({}) do |landed, _store|
      card = landed.fetch(0).vcard.to_s

      assert_includes card, "N:Booles;Jane;;;\r\n"
      assert_includes card, "FN:Jane Booles\r\n"
      assert_includes card, "NOTE:Met at work\r\n"
      assert_includes card, "item1.ADR;type=HOME:;;1 Main St;Springfield;;;\r\n"
    end
  end

  # A grouped property this book reads keeps the label that names it:
  # the row is coming in, so the name for it is too.
  def test_a_label_on_a_line_that_comes_in_comes_with_it
    land({}) do |landed, _store|
      assert_includes landed.fetch(0).vcard.to_s, "item1.X-ABLabel:_$!<Home>!$_\r\n"
    end
  end

  # Nobody has to say so: a property no screen here shows is not
  # carried in, and the label that named it goes with it.
  def test_a_property_no_screen_shows_does_not_come_in
    land({}) do |landed, _store|
      card = landed.fetch(0).vcard.to_s

      refute_includes card, "X-SOCIALPROFILE"
      refute_includes card, "X-ABRELATEDNAMES"
      refute_includes card, "_$!<Spouse>!$_"
    end
  end

  # Saying so explicitly is the same thing.
  def test_dropping_is_what_a_drop_asks_for
    land({"X-SOCIALPROFILE" => Vcf::DROP}) do |landed, _store|
      refute_includes landed.fetch(0).vcard.to_s, "X-SOCIALPROFILE"
    end
  end

  # The note is the way out for a value worth reading even with no
  # field to read it in. It is called what the row was called, not
  # what the property was named.
  def test_a_noted_property_is_written_under_the_note_by_its_label
    land({"X-ABRELATEDNAMES" => Vcf::NOTE}) do |landed, _store|
      card = landed.fetch(0).vcard.to_s

      refute_includes card, "X-ABRELATEDNAMES"
      refute_includes card, "_$!<Spouse>!$_"
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
