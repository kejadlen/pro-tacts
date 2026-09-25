require_relative "../../test_helper"

require "json"

require "pro_tacts/import/monica"
require "pro_tacts/import/vcf"

# Reading Monica 4's JSON export as the .vcf the walk already imports
# (docs/plans/2026-09-25-importing-from-monica.md). The export here is
# spelled the way Monica's export resources write one
# (app/ExportResources on its 4.x branch): a record's columns, its
# `properties`, and its `data` as `{count, type, values}` collections.
class ImportMonicaTest < Minitest::Test
  Monica = ProTacts::Import::Monica
  Vcf = ProTacts::Import::Vcf

  PHONE = "type-phone"
  EMAIL = "type-email"
  TWITTER = "type-twitter"

  # A red pixel, as the data URL Monica's Photo resource writes.
  PIXEL = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

  def collection(type, values)
    {"count" => values.length, "type" => type, "values" => values}
  end

  def jane(**properties)
    {
      "uuid" => "jane-uuid",
      "properties" => {
        "first_name" => "Jane", "last_name" => "Booles", "nickname" => "JB",
        "company" => "Acme", "job" => "Welder",
        "description" => "Met at the co-op.",
        "food_preferences" => "No cilantro",
        "tags" => ["school", "book club"],
        "avatar" => {"avatar_source" => "photo", "avatar_photo" => "photo-uuid"},
        "birthdate" => {"is_age_based" => false, "is_year_unknown" => false,
                        "date" => "1980-05-02T00:00:00.000000Z"},
        "first_met_through" => "sam-uuid",
        **properties,
      },
      "data" => [
        collection("contact_field", [
          {"uuid" => "f1", "properties" => {"data" => "+1 555 0100", "type" => PHONE}},
          {"uuid" => "f2", "properties" => {"data" => "jane@example.com", "type" => EMAIL}},
          {"uuid" => "f3", "properties" => {"data" => "janeb", "type" => TWITTER}},
        ]),
        collection("note", [
          {"uuid" => "n1", "properties" => {"body" => "Likes jigsaws."}},
          {"uuid" => "n2", "properties" => {"body" => "Owes us a casserole dish."}},
        ]),
        collection("address", [
          {"uuid" => "a1", "properties" => {"name" => "Home", "street" => "1 Main St", "city" => "Springfield",
                                            "province" => "IL", "postal_code" => "62701", "country" => "US"}},
        ]),
        collection("pet", [{"uuid" => "p1", "properties" => {"name" => "Rex", "category" => "dog"}}]),
        collection("reminder", [{"uuid" => "r1", "properties" => {"title" => "Call about the dish",
                                                                  "initial_date" => "2026-10-01T00:00:00Z"}}]),
        collection("activity", ["act-uuid"]),
      ],
    }
  end

  def sam
    {"uuid" => "sam-uuid", "properties" => {"first_name" => "Sam", "last_name" => "Booles"}}
  end

  # Known by name only, from Jane's page: a relative, not a contact.
  def aunt
    {"uuid" => "aunt-uuid", "properties" => {"first_name" => "Edna", "is_partial" => true}}
  end

  def export(*contacts, relationships: [])
    JSON.generate({
      "version" => "1.0-preview.1",
      "account" => {
        "uuid" => "account",
        "data" => [
          collection("contact", contacts),
          collection("relationship", relationships),
          collection("photo", [{"uuid" => "photo-uuid",
                                "properties" => {"dataUrl" => "data:image/png;base64,#{PIXEL}"}}]),
          collection("activity", [{"uuid" => "act-uuid",
                                   "properties" => {"summary" => "Picnic", "happened_at" => "2026-06-01T00:00:00Z"}}]),
        ],
        "instance" => {
          "contact_field_types" => [
            {"uuid" => PHONE, "properties" => {"name" => "Phone", "type" => "phone"}},
            {"uuid" => EMAIL, "properties" => {"name" => "Email", "type" => "email"}},
            {"uuid" => TWITTER, "properties" => {"name" => "Twitter"}},
          ],
        },
      },
    })
  end

  def relationship(from, type, to)
    {"uuid" => "#{from}-#{to}", "properties" => {"type" => type, "contact_is" => from, "of_contact" => to}}
  end

  def card_for(bytes, name)
    Vcf.cards(Monica.vcf(bytes)).find { it.property("FN")&.text == name }
  end

  def test_an_export_is_told_from_a_vcf_by_its_first_character
    assert Monica.export?("\n  {\"account\": {}}")
    refute Monica.export?("BEGIN:VCARD\r\n")
  end

  def test_each_contact_becomes_a_card_the_walk_reads
    cards = Vcf.cards(Monica.vcf(export(jane, sam)))

    assert_equal ["Jane Booles", "Sam Booles"], cards.map { it.property("FN").text }
    assert(cards.all?(&:card?))
  end

  def test_the_fields_this_book_shows_come_in
    card = Vcf.read(card_for(export(jane, sam), "Jane Booles")).card

    assert_equal "Booles;Jane;;;", card.property("N").value
    assert_equal "JB", card.property("NICKNAME").text
    assert_equal "Acme", card.property("ORG").text
    assert_equal "1980-05-02", card.property("BDAY").value
    assert_equal "+1 555 0100", card.property("TEL").text
    assert_equal "jane@example.com", card.property("EMAIL").text
    assert_equal ";;1 Main St;Springfield;IL;62701;US", card.property("ADR").value
    assert_equal "Home", card.property("X-ABLabel").text
    assert_equal PIXEL, card.property("PHOTO").value
  end

  # One NOTE, the invariant a contact keeps
  # (docs/plans/2026-09-25-one-note-per-contact.md): the prose first,
  # then what Monica keeps as records, spelled out.
  def test_the_prose_joins_into_the_one_note
    rels = [relationship("jane-uuid", "spouse", "sam-uuid"), relationship("jane-uuid", "bestfriend", "aunt-uuid")]
    card = card_for(export(jane, sam, aunt, relationships: rels), "Jane Booles")
    notes = card.properties.select { it.name == "NOTE" }

    assert_equal 1, notes.length
    assert_equal <<~NOTE.chomp, notes.fetch(0).text
      Met at the co-op.

      Likes jigsaws.

      Owes us a casserole dish.

      Spouse: Sam Booles
      Best friend: Edna

      Pet: Rex (dog)

      Food preferences: No cilantro

      Met through Sam Booles
    NOTE
  end

  def test_a_relative_known_only_by_name_is_not_a_card
    names = Vcf.cards(Monica.vcf(export(jane, aunt))).map { it.property("FN").text }

    assert_equal ["Jane Booles"], names
  end

  # What no screen here shows is on the card as exported, to be struck
  # there and copied by hand where it is worth it.
  def test_what_this_book_does_not_show_is_left_behind_in_view
    dropped = Vcf.read(card_for(export(jane), "Jane Booles")).dropped.map { Vcf.summary(it) }

    assert_includes dropped, "TITLE:Welder"
    assert_includes dropped, "X-SOCIALPROFILE;type=Twitter:janeb"
    assert_includes dropped, "X-MONICA-REMINDER:2026-10-01 — Call about the dish"
    assert_includes dropped, "X-MONICA-ACTIVITY:2026-06-01 — Picnic"
  end

  def test_tags_arrive_as_the_card_s_categories
    card = card_for(export(jane), "Jane Booles")

    assert_equal ["school", "book club"], Vcf.categories(card)
  end

  def test_a_birthday_without_its_year_is_one_a_card_can_spell
    card = card_for(export(jane("birthdate" => {"is_year_unknown" => true, "date" => "2020-05-02T00:00:00Z"})),
                    "Jane Booles")

    assert_equal "1604-05-02", card.property("BDAY").value
  end

  # Worked out from an age: a year Monica guessed and a day it made up.
  def test_a_birthday_monica_guessed_from_an_age_is_left_behind
    card = card_for(export(jane("birthdate" => {"is_age_based" => true, "date" => "1980-01-01T00:00:00Z"})),
                    "Jane Booles")

    assert_nil card.property("BDAY")
    assert_equal "about 1980", card.property("X-MONICA-AGE-BASED-BIRTHDAY").text
  end

  def test_json_that_is_not_a_monica_export_is_refused
    error = assert_raises(Vcf::Invalid) { Monica.vcf("{\"contacts\": []}") }

    assert_includes error.message, "not a Monica export"
  end

  def test_a_file_that_will_not_parse_is_refused
    assert_raises(Vcf::Invalid) { Monica.vcf("{not json") }
  end

  def test_an_export_of_nobody_is_refused
    error = assert_raises(Vcf::Invalid) { Monica.vcf(export(aunt)) }

    assert_includes error.message, "no contacts"
  end
end
