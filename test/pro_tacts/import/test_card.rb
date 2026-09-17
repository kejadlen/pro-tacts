require_relative "../../test_helper"

require "pathname"
require "tmpdir"

require "pro_tacts/import/card"

class ImportCardTest < Minitest::Test
  Card = ProTacts::Import::Card

  ADA = <<~YAML
    first: Ada
    last: Lovelace
    phones:
    - "+12532189075"
    groups:
    - sync:*
    - import-20260916T180412Z
  YAML

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
    assert_equal Card.new(first: "Ada", last: "Lovelace", phones: ["+12532189075"], groups: ["sync:*", "import-20260916T180412Z"]), read(ADA)
  end

  def test_a_card_is_the_contact_the_web_create_and_add_rows_make
    contact = read(ADA).contact("kmnuqmzxylru")

    assert_equal "kmnuqmzxylru", contact.id
    assert_equal "BEGIN:VCARD\r\nVERSION:3.0\r\nN:Lovelace;Ada;;;\r\nFN:Ada Lovelace\r\nUID:kmnuqmzxylru\r\nTEL:+12532189075\r\nEND:VCARD\r\n", contact.vcard.to_s
  end

  def test_a_name_is_escaped_into_the_card
    card = Card.new(first: "Ada; Countess", last: "", phones: [], groups: [])

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
    assert_invalid "#{ADA}emails: []\n", "has emails, which no field takes"
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

  def test_a_blank_group_is_refused
    assert_invalid ADA.sub("- sync:*", "- ''"), "groups must be a list of names"
  end

  def test_a_file_that_is_not_a_mapping_is_refused
    assert_invalid "- Ada\n", "is not a mapping"
  end
end
