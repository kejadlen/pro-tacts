require_relative "../test_helper"

require "digest"

require "pro_tacts/contact"

class ContactTest < Minitest::Test
  CARD = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nEND:VCARD\r\n"

  STRUCTURED = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Ada Lovelace\r\nN:Lovelace;Ada;;;\r\n" \
    "TEL;TYPE=mobile:+1-555-0100\r\nTEL;TYPE=work:+1-555-0199\r\n" \
    "EMAIL;TYPE=home:ada@example.com\r\n" \
    "ADR;TYPE=home:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n" \
    "BDAY:1985-12-10\r\nNOTE:Countess\\, mathematician.\r\nUID:ada\r\nEND:VCARD\r\n"

  def contact(vcard)
    ProTacts::Contact.for(id: "aiden", vcard:)
  end

  def test_the_etag_hashes_the_card
    contact = ProTacts::Contact.for(id: "aiden", vcard: CARD)

    assert_equal %("#{Digest::SHA256.hexdigest(CARD)}"), contact.etag
  end

  def test_the_etag_moves_with_the_card
    etag = ProTacts::Contact.for(id: "aiden", vcard: CARD).etag

    assert_equal etag, ProTacts::Contact.for(id: "aiden", vcard: CARD).etag
    refute_equal etag, ProTacts::Contact.for(id: "aiden", vcard: CARD.sub("Aiden", "Aiden Smith")).etag
  end

  # The same card under two ids is two contacts with the same etag: the
  # etag is about the bytes a client downloads, and the id is not in them.
  def test_the_etag_ignores_the_id
    assert_equal(
      ProTacts::Contact.for(id: "aiden", vcard: CARD).etag,
      ProTacts::Contact.for(id: "znorth", vcard: CARD).etag,
    )
  end

  def test_ids_outside_the_href_charset_raise
    ["John Smith", "../etc/passwd", "a/b", ""].each do |id|
      error = assert_raises(ArgumentError) { ProTacts::Contact.for(id:, vcard: CARD) }

      assert_equal "invalid contact id: #{id}", error.message
    end
  end

  def test_uuids_and_slugs_are_ids
    %w[AB12C345-6789-0DEF-1234-567890ABCDEF aiden znorth_2].each do |id|
      assert_equal id, ProTacts::Contact.for(id:, vcard: CARD).id
    end
  end

  # The parse is lazy so the serving paths never pay it: ctag and the
  # listings build a contact per row without reading structure, and a
  # card that will not parse is still served byte for byte.
  def test_making_a_contact_never_parses_the_card
    assert_equal "aiden", contact("not a vCard at all").id
  end

  def test_reads_the_name
    assert_equal "Ada Lovelace", contact(STRUCTURED).name
  end

  def test_reads_the_name_components
    assert_equal ["Lovelace", "Ada", "", "", ""], contact(STRUCTURED).name_components
  end

  def test_values_come_back_unescaped
    escaped = STRUCTURED.sub("FN:Ada Lovelace", "FN:Ada\\, Countess of Lovelace")

    assert_equal "Ada, Countess of Lovelace", contact(escaped).name
  end

  def test_reads_every_phone_with_its_type
    assert_equal [["+1-555-0100", "mobile"], ["+1-555-0199", "work"]],
      contact(STRUCTURED).phones.map { [it.value, it.type] }
  end

  def test_reads_email
    emails = contact(STRUCTURED).emails
    assert_equal 1, emails.length
    assert_equal "ada@example.com", emails.fetch(0).value
    assert_equal "home", emails.fetch(0).type
  end

  def test_reads_an_address_as_its_seven_components
    address = contact(STRUCTURED).addresses.fetch(0)
    assert_equal "", address.po_box
    assert_equal "", address.extended
    assert_equal "12 Analytical Way", address.street
    assert_equal "London", address.locality
    assert_equal "England", address.region
    assert_equal "NW1 1AA", address.postal_code
    assert_equal "United Kingdom", address.country
    assert_equal "home", address.type
  end

  # Components the card's value stopped short of are nil, not empty —
  # only a delimiter the value actually carried makes an empty one.
  def test_address_components_beyond_the_value_are_nil
    short = STRUCTURED.sub(
      "ADR;TYPE=home:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom",
      "ADR:;;12 Analytical Way",
    )
    address = contact(short).addresses.fetch(0)

    assert_nil address.locality
    assert_nil address.region
    assert_nil address.postal_code
    assert_nil address.country
  end

  def test_the_birthday_is_the_model_the_store_composed
    assert_equal ProTacts::Birthday.new(year: 1985, month: 12, day: 10), contact(STRUCTURED).birthday
  end

  # A BDAY in a spelling the model does not recompose stays in the card
  # verbatim; the accessor reads nil, and showing it as stored is the
  # substrate's job (Format.birthday).
  def test_an_unmodeled_birthday_spelling_reads_nil
    unmodeled = STRUCTURED.sub("BDAY:1985-12-10", "BDAY:not-a-date")

    assert_nil contact(unmodeled).birthday
  end

  def test_unescapes_notes
    assert_equal "Countess, mathematician.", contact(STRUCTURED).notes
  end

  def test_properties_are_the_parsed_card
    properties = contact(STRUCTURED).properties

    assert_equal "BEGIN", properties.fetch(0).name
    assert properties.any? { it.name.casecmp?("TEL") }
  end

  def test_attributes_with_no_data_are_nil_or_empty
    bare = contact("BEGIN:VCARD\r\nVERSION:3.0\r\nUID:bare\r\nEND:VCARD\r\n")

    assert_nil bare.name
    assert_nil bare.name_components
    assert_empty bare.phones
    assert_empty bare.emails
    assert_empty bare.addresses
    assert_nil bare.birthday
    assert_nil bare.notes
  end

  # A card that will not read is still a contact: the bytes are what
  # gets served, and no accessor has a repair to offer for a line the
  # parser cannot read. The accessors answer from the lines that read
  # and say nothing about the rest.
  def test_a_card_that_will_not_parse_answers_from_what_read
    assert_empty contact("not a vCard at all").phones
    assert_empty contact("not a vCard at all").properties
    assert_equal "Aiden", contact("FN:Aiden\r\nTEL;HOME:+1-555-1234\r\n").name
  end
end
