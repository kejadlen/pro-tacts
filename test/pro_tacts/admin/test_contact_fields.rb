require_relative "../../test_helper"

require "pro_tacts/admin/contact_fields"
require "pro_tacts/contact"

class ContactFieldsTest < Minitest::Test
  def fields(vcard)
    ProTacts::Admin::ContactFields.from(ProTacts::Contact.for(id: "aiden", vcard:))
  end

  CARD = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Ada Lovelace\r\n" \
    "TEL;TYPE=mobile:+1-555-0100\r\nTEL;TYPE=work:+1-555-0199\r\n" \
    "EMAIL;TYPE=home:ada@example.com\r\n" \
    "ADR;TYPE=home:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n" \
    "BDAY:1985-12-10\r\nNOTE:Countess\\, mathematician.\r\nUID:ada\r\nEND:VCARD\r\n"

  def test_reads_the_name
    assert_equal "Ada Lovelace", fields(CARD).name
  end

  def test_reads_every_phone_with_its_type
    assert_equal [["+1-555-0100", "mobile"], ["+1-555-0199", "work"]],
      fields(CARD).phones.map { [it.value, it.type] }
  end

  def test_reads_email
    emails = fields(CARD).emails
    assert_equal 1, emails.length
    assert_equal "ada@example.com", emails.fetch(0).value
    assert_equal "home", emails.fetch(0).type
  end

  def test_reads_address_as_two_lines
    addresses = fields(CARD).addresses
    assert_equal 1, addresses.length
    address = addresses.fetch(0)
    assert_equal ["12 Analytical Way", "London, England, NW1 1AA", "United Kingdom"], address.lines
    assert_equal "home", address.type
  end

  def test_formats_the_birthday
    assert_equal "December 10, 1985", fields(CARD).birthday
  end

  def test_unescapes_notes
    assert_equal "Countess, mathematician.", fields(CARD).notes
  end

  def test_attributes_with_no_data_are_nil_or_empty
    bare = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Bare\r\nUID:bare\r\nEND:VCARD\r\n"
    fields = fields(bare)

    assert_empty fields.phones
    assert_empty fields.emails
    assert_empty fields.addresses
    assert_nil fields.birthday
    assert_nil fields.notes
  end

  # Unlike Store#rebuild_index, which fails a card open because a
  # write already guarantees every stored card parses (VCard.card? is
  # checked before a PUT is accepted) — a card that reaches here and
  # still won't parse is a bug or a corrupt row, not the ordinary case,
  # and it should raise into Sentry rather than render a blank card.
  def test_a_card_that_will_not_parse_raises
    assert_raises(ProTacts::VCard::ParseError) { fields("not a vCard at all") }
  end

  # RFC 2426 section 3.1.5 lets BDAY carry a date-time, and a client is
  # free to send one; the display only reads the date part of it.
  def test_a_birthday_with_a_time_component_still_formats
    with_time = CARD.sub("BDAY:1985-12-10", "BDAY:1985-12-10T00:00:00Z")

    assert_equal "December 10, 1985", fields(with_time).birthday
  end

  # Apple's 1604-sentinel spelling for "no year on file" (see
  # ProTacts::Birthday), the shape a served card actually carries.
  def test_a_birthday_with_no_year_omits_one
    no_year = CARD.sub("BDAY:1985-12-10", "BDAY;X-APPLE-OMIT-YEAR=1604:1604-12-10")

    assert_equal "December 10", fields(no_year).birthday
  end

  def test_a_birthday_that_will_not_parse_is_shown_as_stored
    unparseable = CARD.sub("BDAY:1985-12-10", "BDAY:not-a-date")

    assert_equal "not-a-date", fields(unparseable).birthday
  end
end
