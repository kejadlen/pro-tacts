require_relative "../../test_helper"

require "pathname"
require "tmpdir"

require "pro_tacts/import/card"

class ImportCardTest < Minitest::Test
  Card = ProTacts::Import::Card

  ADA = <<~YAML
    first: Ada
    last: Lovelace
    nickname: The Countess
    birthday: '1815-12-10'
    phones:
    - "+12532189075"
    emails:
    - ada@example.com
    addresses:
    - street: 12 Marylebone
      locality: London
    note: An analyst.
    photo: false
    groups:
    - sync:*
    - import-20260916T180412Z
    source:
      identifier: A:ABPerson
      vcard: "BEGIN:VCARD\\r\\nEND:VCARD\\r\\n"
      note:
      contact: {}
  YAML

  SOURCE = {"identifier" => "A:ABPerson", "vcard" => "BEGIN:VCARD\r\nEND:VCARD\r\n", "note" => nil, "contact" => {}}.freeze

  def read(yaml)
    Dir.mktmpdir do |tmp|
      path = Pathname.new(tmp) / "kmnuqmzxylru.yml"
      path.write(yaml)
      Card.read(path)
    end
  end

  def assert_invalid(yaml, message)
    error = assert_raises(Card::Invalid) { read(yaml) }
    assert_includes error.message, message
  end

  def test_a_card_reads_its_fields
    assert_equal Card.new(first: "Ada", last: "Lovelace", nickname: "The Countess", birthday: "1815-12-10", phones: ["+12532189075"], emails: ["ada@example.com"], addresses: [{"street" => "12 Marylebone", "locality" => "London"}], note: "An analyst.", photo: false, groups: ["sync:*", "import-20260916T180412Z"], source: SOURCE), read(ADA)
  end

  def test_a_card_is_the_contact_the_web_create_and_add_rows_make
    contact = read(ADA).contact("kmnuqmzxylru")

    assert_equal "kmnuqmzxylru", contact.id
    assert_equal <<~CARD.gsub("\n", "\r\n"), contact.vcard.to_s
      BEGIN:VCARD
      VERSION:3.0
      N:Lovelace;Ada;;;
      FN:Ada Lovelace
      UID:kmnuqmzxylru
      NICKNAME:The Countess
      NOTE:An analyst.
      TEL:+12532189075
      EMAIL:ada@example.com
      ADR:;;12 Marylebone;London;;;
      BDAY:1815-12-10
      END:VCARD
    CARD
  end

  def test_a_name_is_escaped_into_the_card
    card = Card.new(first: "Ada; Countess", last: "", nickname: nil, birthday: nil, phones: [], emails: [], addresses: [], note: nil, photo: false, groups: [], source: SOURCE)

    assert_equal ["Ada; Countess"], [card.contact("kmnuqmzxylru").name]
  end

  def test_the_document_reads_back_as_the_card
    card = read(ADA)

    assert_equal card, read(YAML.dump(card.document))
  end

  def test_a_missing_field_is_refused
    assert_invalid ADA.sub("phones:\n- \"+12532189075\"\n", ""), "has no phones"
  end

  def test_a_field_no_card_takes_is_refused
    assert_invalid "#{ADA}url: https://example.com\n", "has url, which no field takes"
  end

  def test_an_unquoted_number_is_refused
    assert_invalid ADA.sub('"+12532189075"', "+12532189075"), "phones must be a list of quoted numbers"
  end

  def test_a_name_yaml_reads_as_something_else_is_refused
    assert_invalid ADA.sub("last: Lovelace", "last: no"), "first and last must be text"
  end

  def test_a_card_with_no_name_is_refused
    assert_invalid ADA.sub("first: Ada", "first: ''").sub("last: Lovelace", "last: ' '"), "needs a first or last name"
  end

  def test_an_unquoted_date_is_refused
    assert_invalid ADA.sub("birthday: '1815-12-10'", "birthday: 1815-12-10"), "reads as a Date; quote it"
  end

  def test_a_birthday_that_is_not_a_whole_date_is_refused
    assert_invalid ADA.sub("birthday: '1815-12-10'", "birthday: '--12-10'"), "birthday must be a quoted YYYY-MM-DD"
  end

  def test_a_card_with_no_birthday_reads_and_writes_the_blank
    card = read(ADA.sub("birthday: '1815-12-10'", "birthday:"))

    assert_nil card.birthday
    refute_includes card.contact("kmnuqmzxylru").vcard.to_s, "BDAY"
  end

  def test_an_address_part_no_field_takes_is_refused
    assert_invalid ADA.sub("  locality: London", "  po_box: '4'"), "addresses must be a list, each with any of"
  end

  def test_a_picture_the_source_holds_is_a_photo_line
    jpeg = ["\xFF\xD8\xFFhello".b].pack("m0")
    source = SOURCE.merge("contact" => {"imageData" => jpeg})
    card = read(ADA.sub("photo: false", "photo: true").sub("  contact: {}", "  contact:\n    imageData: #{jpeg}"))

    assert_equal source.fetch("contact"), card.source.fetch("contact")
    assert_includes card.contact("kmnuqmzxylru").vcard.to_s, "PHOTO;ENCODING=b;TYPE=JPEG:#{jpeg}\r\n"
    assert_equal "image/jpeg", card.contact("kmnuqmzxylru").photo.mime_type
  end

  def test_a_photo_the_source_cannot_supply_is_refused
    assert_invalid ADA.sub("photo: false", "photo: true"), "photo is true and the source holds no picture"
  end

  def test_a_blank_group_is_refused
    assert_invalid ADA.sub("- sync:*", "- ''"), "groups must be a list of names"
  end

  def test_a_file_that_is_not_a_mapping_is_refused
    assert_invalid "- Ada\n", "is not a mapping"
  end
end
