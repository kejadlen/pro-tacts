# frozen_string_literal: true

require_relative "../test_helper"

require "pro_tacts/profile"

class ProfileTest < Minitest::Test
  def render(hostname: "example.ts.net")
    ProTacts::Profile.render(hostname:)
  end

  def test_is_well_formed_xml
    refute_nil Nokogiri::XML(render).root
  end

  def test_carries_the_carddav_payload_type
    assert_includes render, "<string>com.apple.carddav.account</string>"
  end

  def test_embeds_hostname_and_fixed_dev_credentials
    xml = render

    assert_includes xml, "<string>example.ts.net</string>"
    assert_includes xml, "<string>alpha@example.com</string>"
    assert_includes xml, "<string>carddav-dev</string>"
  end

  def test_enables_ssl
    assert_match(/<key>CardDAVUseSSL<\/key>\s*<true\/>/, render)
  end

  def test_omits_principal_url_to_leave_server_path_empty
    refute_includes render, "CardDAVPrincipalURL"
  end

  def test_identifiers_are_stable_across_renders
    assert_equal render, render
    assert_includes render, ProTacts::Profile::PAYLOAD_IDENTIFIER
  end

  def test_escapes_xml_in_field_values
    xml = render(hostname: "a&b.ts.net")

    assert_includes xml, "<string>a&amp;b.ts.net</string>"
    refute_includes xml, "<string>a&b.ts.net</string>"
    assert_empty Nokogiri::XML(xml).errors
  end
end
