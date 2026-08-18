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

  def test_identifiers_are_fresh_per_render
    first, second = render, render

    refute_equal first, second
    assert_includes first, ProTacts::Profile::IDENTIFIER_PREFIX
    assert_includes second, ProTacts::Profile::IDENTIFIER_PREFIX
  end

  def test_uuids_are_well_formed
    xml = render

    uuids = xml.scan(%r{<string>([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})</string>})
    assert_equal 2, uuids.uniq.size
  end

  def test_installed_identifiers_picks_out_pro_tacts_profiles
    list_output = <<~OUTPUT
      _admin-Profiles-1
          identifier: #{ProTacts::Profile::IDENTIFIER_PREFIX}-20260818ab12

      _admin-Profiles-2
          identifier: com.example.unrelated

      _admin-Profiles-3
          identifier: #{ProTacts::Profile::IDENTIFIER_PREFIX}-20260818cd34
    OUTPUT

    assert_equal [
      "#{ProTacts::Profile::IDENTIFIER_PREFIX}-20260818ab12",
      "#{ProTacts::Profile::IDENTIFIER_PREFIX}-20260818cd34"
    ], ProTacts::Profile.installed_identifiers(list_output)
  end

  def test_installed_identifiers_reads_attribute_format_output
    list_output = <<~OUTPUT
      alpha[1] attribute: profileIdentifier: #{ProTacts::Profile::IDENTIFIER_PREFIX}-20260818155835720a9db
      There are 1 user configuration profiles installed for 'alpha'
    OUTPUT

    assert_equal ["#{ProTacts::Profile::IDENTIFIER_PREFIX}-20260818155835720a9db"],
      ProTacts::Profile.installed_identifiers(list_output)
  end

  def test_installed_identifiers_reads_table_format_output
    list_output = <<~OUTPUT
      Profiles:
          identifier                             display name
          ------------------------------------   --------------
          #{ProTacts::Profile::IDENTIFIER_PREFIX}-20260818ab12   pro-tacts CardDAV
          com.example.unrelated                  Work
      OUTPUT

    assert_equal ["#{ProTacts::Profile::IDENTIFIER_PREFIX}-20260818ab12"],
      ProTacts::Profile.installed_identifiers(list_output)
  end

  def test_installed_identifiers_ignores_longer_identifiers_containing_the_prefix
    list_output = "com.example.#{ProTacts::Profile::IDENTIFIER_PREFIX}-fake\n"

    assert_empty ProTacts::Profile.installed_identifiers(list_output)
  end

  def test_installed_identifiers_is_empty_without_ours
    list_output = "  identifier: com.example.unrelated\n"

    assert_empty ProTacts::Profile.installed_identifiers(list_output)
  end

  def test_escapes_xml_in_field_values
    xml = render(hostname: "a&b.ts.net")

    assert_includes xml, "<string>a&amp;b.ts.net</string>"
    refute_includes xml, "<string>a&b.ts.net</string>"
    assert_empty Nokogiri::XML(xml).errors
  end
end
