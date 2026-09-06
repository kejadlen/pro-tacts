require_relative "../test_helper"
require_relative "../photo_card"

require "base64"
require "digest"

require "pro_tacts/contact"
require "pro_tacts/vcard"

class ContactTest < Minitest::Test
  include Sentry::TestHelper
  include SentryMessages

  CARD = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nEND:VCARD\r\n"

  STRUCTURED = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Ada Lovelace\r\nN:Lovelace;Ada;;;\r\n" \
    "TEL;TYPE=mobile:+1-555-0100\r\nTEL;TYPE=work:+1-555-0199\r\n" \
    "EMAIL;TYPE=home:ada@example.com\r\n" \
    "ADR;TYPE=home:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom\r\n" \
    "NOTE:Countess\\, mathematician.\r\nUID:ada\r\nEND:VCARD\r\n"

  # The production shapes (see the class comment): a modeled birthday
  # passes a BDAY-free card beside a Birthday, and a fallback case
  # passes a card carrying an unmodeled BDAY beside nil — no stored
  # card ever carries a BDAY the model recomposes.
  def contact(vcard = CARD, id: "aiden", birthday: nil)
    ProTacts::Contact.for(id:, stored: ProTacts::VCard.new(vcard), birthday:)
  end

  # The decode's refusal reports (see #photo); the transport this pins
  # holds it for the assertions below, and teardown clears it.
  def setup
    setup_sentry
  end

  def teardown
    teardown_sentry_test
  end

  def test_the_etag_hashes_the_card
    assert_equal %("#{Digest::SHA256.hexdigest(CARD)}"), contact.etag
  end

  # The etag hashes the composed card, not the stored one, so it moves
  # when a birthday moves even though the bytes on disk do not.
  def test_the_etag_hashes_the_composed_card
    birthday = ProTacts::Birthday.new(year: 1985, month: 12, day: 10)
    composed = CARD.sub("END:VCARD\r\n", "BDAY:1985-12-10\r\nEND:VCARD\r\n")

    assert_equal %("#{Digest::SHA256.hexdigest(composed)}"), contact(CARD, birthday:).etag
  end

  def test_the_etag_moves_with_the_card
    etag = contact.etag

    assert_equal etag, contact.etag
    refute_equal etag, contact(CARD.sub("Aiden", "Aiden Smith")).etag
  end

  # The same card under two ids is two contacts with the same etag: the
  # etag is about the bytes a client downloads, and the id is not in them.
  def test_the_etag_ignores_the_id
    assert_equal contact(id: "aiden").etag, contact(id: "znorth").etag
  end

  def test_ids_outside_the_href_charset_raise
    ["John Smith", "../etc/passwd", "a/b", ""].each do |id|
      error = assert_raises(ArgumentError) { contact(id:) }

      assert_equal "invalid contact id: #{id}", error.message
    end
  end

  def test_uuids_and_slugs_are_ids
    %w[AB12C345-6789-0DEF-1234-567890ABCDEF aiden znorth_2].each do |id|
      assert_equal id, contact(id:).id
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
    assert_equal ["Lovelace", "Ada", nil, nil, nil], contact(STRUCTURED).name_components
  end

  def test_reads_the_nickname
    nicknamed = CARD.sub("FN:Aiden\r\n", "FN:Aiden\r\nNICKNAME:Red\r\n")

    assert_equal "Red", contact(nicknamed).nickname
    assert_nil contact(CARD).nickname
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
    assert_nil address.po_box
    assert_nil address.extended
    assert_equal "12 Analytical Way", address.street
    assert_equal "London", address.locality
    assert_equal "England", address.region
    assert_equal "NW1 1AA", address.postal_code
    assert_equal "United Kingdom", address.country
    assert_equal "home", address.type
  end

  # A blank position and one past the end of the value read the same:
  # neither says anything the card did not.
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

  # An empty value carries nothing a missing property would not, so
  # the accessors read one as the other: FN:, NOTE:, TEL:, and EMAIL:
  # come back absent, and an ADR blank throughout is no address.
  def test_empty_values_read_as_absent
    empty = STRUCTURED.sub("FN:Ada Lovelace", "FN:")
      .sub("TEL;TYPE=mobile:+1-555-0100", "TEL;TYPE=mobile:")
      .sub("TEL;TYPE=work:+1-555-0199", "TEL;TYPE=work:")
      .sub("EMAIL;TYPE=home:ada@example.com", "EMAIL;TYPE=home:")
      .sub("ADR;TYPE=home:;;12 Analytical Way;London;England;NW1 1AA;United Kingdom", "ADR;TYPE=home:;")
      .sub("NOTE:Countess\\, mathematician.", "NOTE:")

    contact = contact(empty)
    assert_nil contact.name
    assert_empty contact.phones
    assert_empty contact.emails
    assert_empty contact.addresses
    assert_nil contact.notes
  end

  # The birthday is the model held beside the card, not a parse of
  # the card it composes into — the reader returns the store's fact.
  def test_the_birthday_is_the_one_held_beside_the_card
    birthday = ProTacts::Birthday.new(year: 1985, month: 12, day: 10)

    assert_equal birthday, contact(STRUCTURED, birthday:).birthday
  end

  # The served card is the stored one with the birthday's line composed
  # in immediately before END:VCARD — the bytes a client downloads.
  def test_the_served_card_composes_the_birthday_in
    birthday = ProTacts::Birthday.new(year: 1985, month: 12, day: 10)
    composed = STRUCTURED.sub("END:VCARD\r\n", "BDAY:1985-12-10\r\nEND:VCARD\r\n")

    assert_equal composed, contact(STRUCTURED, birthday:).vcard.to_s
  end

  # A birthday with no wire form — the shapes no client renders —
  # composes nothing, and the stored card serves exactly as it is.
  def test_a_birthday_with_no_wire_form_leaves_the_card_as_stored
    year_alone = ProTacts::Birthday.new(year: 1985)

    assert_equal STRUCTURED, contact(STRUCTURED, birthday: year_alone).vcard.to_s
  end

  # A BDAY in a spelling the model does not recompose stays in the card
  # verbatim; the reader answers nil over it, and showing it as stored
  # is the substrate's job (Format.birthday).
  def test_an_unmodeled_birthday_spelling_reads_nil
    unmodeled = STRUCTURED.sub("END:VCARD\r\n", "BDAY:not-a-date\r\nEND:VCARD\r\n")

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
    assert_nil bare.nickname
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

  ## Photos

  # The picture the card carries, decoded: PHOTO's base64 payload as
  # bytes, with the mime type read off the decoded bytes themselves —
  # magic bytes cannot mislabel what they are — rather than the TYPE
  # parameter. The synthetic payload carries the JPEG signature the
  # builder gives every image.
  def test_a_photo_reads_decoded_with_a_sniffed_type
    photo = contact(PhotoCard.photo("aiden", bytes: 64)).photo

    assert_equal "image/jpeg", photo.mime_type
    assert_equal PhotoCard.image(64), photo.bytes
  end

  # The sniff's other rows: a picture named PNG or GIF reads as what
  # its bytes are, whatever the TYPE parameter said.
  def test_png_and_gif_payloads_sniff_to_their_types
    png = CARD.sub("FN:Aiden\r\n", photo_property("\x89PNG\r\n\x1A\nx"))
    gif = CARD.sub("FN:Aiden\r\n", photo_property("GIF89ax"))

    assert_equal "image/png", contact(png).photo&.mime_type
    assert_equal "image/gif", contact(gif).photo&.mime_type
  end

  def test_a_card_without_a_photo_has_none
    assert_nil contact.photo

    # The one nil that stays quiet: no PHOTO is no news.
    assert_empty sentry_events
  end

  # A URI-form PHOTO never reaches the sniff: a URI's ":" is not in
  # base64's alphabet and the strict decode refuses the value. Same
  # nil for a payload that is not an image a browser can show — the
  # initials an avatar falls back to, an ordinary absence.
  def test_a_photo_that_is_not_showable_has_none
    uri = CARD.sub("FN:Aiden\r\n", "PHOTO;VALUE=uri:https://example.com/me.jpg\r\n")
    undecodable = CARD.sub("FN:Aiden\r\n", "PHOTO;ENCODING=b:not base64!!\r\n")
    not_an_image = CARD.sub("FN:Aiden\r\n", "PHOTO;ENCODING=b:#{Base64.strict_encode64("text, not an image")}\r\n")

    assert_nil contact(uri).photo
    assert_nil contact(undecodable).photo
    assert_nil contact(not_an_image).photo
  end

  # The departure from the accessor's ordinary nils: a value the
  # strict decoder refuses reports on its way to nil — warning-grade,
  # bad-input level, no card content — so a PHOTO this server cannot
  # read is news rather than initials with no why.
  def test_an_undecodable_photo_reports_the_refusal
    undecodable = CARD.sub("FN:Aiden\r\n", "PHOTO;ENCODING=b:not base64!!\r\n")

    assert_nil contact(undecodable).photo

    assert_equal 1, sentry_events.length
    event = sentry_events.fetch(0)
    assert_equal :warning, event.level
    assert_equal "ArgumentError", event.exception.values.first.type
  end

  # The sniff's nil reports too, a message rather than an exception —
  # there is no error to name, only bytes whose format the signature
  # list does not know, and the message is the record that they
  # arrived.
  def test_a_photo_of_no_known_format_warns
    unknown = CARD.sub("FN:Aiden\r\n", "PHOTO;ENCODING=b:#{Base64.strict_encode64("RIFF____WEBP")}\r\n")

    assert_nil contact(unknown).photo

    assert_equal 1, sentry_messages.length
    assert_match(/PHOTO decoded to no image format/, sentry_messages.fetch(0))
  end

  # One PHOTO property carrying a PNG payload, for the sniff's rows.
  def photo_property(payload)
    "PHOTO;ENCODING=b;TYPE=JPEG:#{Base64.strict_encode64(payload)}\r\n"
  end
end
