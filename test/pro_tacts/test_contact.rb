require_relative "../test_helper"

require "digest"

require "pro_tacts/contact"

class ContactTest < Minitest::Test
  CARD = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nEND:VCARD\r\n"

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
end
