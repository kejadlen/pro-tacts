require_relative "../test_helper"
require "sentry-ruby"

require "pro_tacts/sentry_scrubber"

class SentryScrubberTest < Minitest::Test
  CARD = <<~VCARD.chomp
    BEGIN:VCARD
    VERSION:3.0
    UID:AB12C345
    FN:Real Person
    TEL:+1-555-1234
    END:VCARD
  VCARD

  # Stands in for a Sentry event: the scrubber only reaches for #request,
  # and the request only needs a body and headers.
  Event = Struct.new(:request)
  Request = Struct.new(:data, :headers)

  def scrub(data, headers = {})
    event = Event.new(Request.new(data, headers))
    ProTacts::SentryScrubber.call(event, nil)
    event.request.data
  end

  def test_a_card_is_redacted
    refute_includes scrub(CARD), "Real Person"
  end

  def test_a_card_is_replaced_rather_than_emptied
    assert_includes scrub(CARD), "vcard redacted"
  end

  # The redaction has to stop at END:VCARD, not run to the end of the body,
  # or a card anywhere in a request would take the rest of it along.
  def test_a_card_embedded_in_xml_is_redacted_without_eating_what_follows
    scrubbed = scrub("<address-data>#{CARD}</address-data><href>/keep/me</href>")

    refute_includes scrubbed, "Real Person"
    assert_includes scrubbed, "<address-data>"
    assert_includes scrubbed, "</address-data>"
    assert_includes scrubbed, "<href>/keep/me</href>"
  end

  # (?~) is greedy to the longest run holding no complete END:VCARD, which
  # runs into the marker and stops at END:VCAR. Without something forcing it
  # back onto the boundary a stray "D" survives, so assert the exact result
  # rather than just the absence of card content.
  def test_no_fragment_of_the_end_marker_survives
    assert_equal "<d>#{ProTacts::SentryScrubber::REDACTED}</d>TAIL", scrub("<d>#{CARD}</d>TAIL")
  end

  def test_content_between_two_cards_survives
    scrubbed = scrub("#{CARD}\nMIDDLE\n#{CARD.sub('Real Person', 'Other Person')}\nTRAILING")

    refute_includes scrubbed, "Real Person"
    refute_includes scrubbed, "Other Person"
    assert_includes scrubbed, "MIDDLE"
    assert_includes scrubbed, "TRAILING"
  end

  # Only the unterminated card runs to the end; the complete one before it
  # still stops at its own END:VCARD.
  def test_a_complete_card_before_a_truncated_one_stops_at_its_end
    scrubbed = scrub("#{CARD}\nMIDDLE\nBEGIN:VCARD\nFN:Trunc")

    refute_includes scrubbed, "Real Person"
    refute_includes scrubbed, "Trunc"
    assert_includes scrubbed, "MIDDLE"
  end

  def test_several_cards_are_all_redacted
    scrubbed = scrub("#{CARD}\n#{CARD.sub('Real Person', 'Other Person')}")

    refute_includes scrubbed, "Real Person"
    refute_includes scrubbed, "Other Person"
  end

  # Sentry truncates at 16KB, so a card can arrive without its END line.
  def test_a_truncated_card_is_redacted
    refute_includes scrub("BEGIN:VCARD\nVERSION:3.0\nFN:Real Pers"), "Real Pers"
  end

  def test_lowercase_markers_are_redacted
    refute_includes scrub(CARD.downcase), "real person"
  end

  # The href in a multiget names a contact by UID, which is not a secret and
  # is the useful part of a 404 report.
  def test_hrefs_are_left_alone
    body = "<href>/dav/addressbook/AB12C345-6789.vcf</href>"

    assert_equal body, scrub(body)
  end

  def test_a_vcard_content_type_redacts_the_whole_body
    scrubbed = scrub("garbled but still a card", "Content-Type" => "text/vcard; charset=utf-8")

    assert_equal ProTacts::SentryScrubber::REDACTED, scrubbed
  end

  def test_form_bodies_are_walked
    scrubbed = scrub({ "card" => CARD, "id" => "AB12C345" })

    refute_includes scrubbed.fetch("card"), "Real Person"
    assert_equal "AB12C345", scrubbed.fetch("id")
  end

  def test_a_nil_body_is_left_alone
    assert_nil scrub(nil)
  end

  def test_an_event_without_a_request_is_returned_unchanged
    event = Event.new(nil)

    assert_same event, ProTacts::SentryScrubber.call(event, nil)
  end

  # Guards the field names against a sentry-ruby upgrade: this is the real
  # interface Sentry builds from a Rack env, not a stand-in.
  def test_it_scrubs_a_real_sentry_request_interface
    env = Rack::MockRequest.env_for("/dav/addressbook/", method: "PUT", input: CARD)
    env["CONTENT_TYPE"] = "text/xml"
    request = Sentry::RequestInterface.new(env: env, send_default_pii: true, rack_env_whitelist: [])

    assert_includes request.data, "Real Person", "precondition: Sentry captured the body"

    ProTacts::SentryScrubber.call(Event.new(request), nil)

    refute_includes request.data, "Real Person"
  end
end
