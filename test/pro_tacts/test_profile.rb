
require_relative "../test_helper"

require "pro_tacts/profile"

class ProfileTest < Minitest::Test
  def render(hostname: "example.ts.net", username: "ada@example.com")
    ProTacts::Profile.render(hostname:, username:)
  end

  # The name comes from the environment now rather than an argument, so
  # the tests that care about it swap the config the same way the
  # install screen's do.
  def with_config(env = {})
    original = ProTacts.config
    ProTacts.config = ProTacts::Config.new(env)
    yield
  ensure
    ProTacts.config = original
  end

  def test_is_well_formed_xml
    refute_nil Nokogiri::XML(render).root
  end

  def test_carries_the_carddav_payload_type
    assert_includes render, "<string>com.apple.carddav.account</string>"
  end

  def test_embeds_hostname_username_and_placeholder_password
    xml = render

    assert_includes xml, "<string>example.ts.net</string>"
    assert_match(%r{<key>CardDAVUsername</key>\s*<string>ada@example.com</string>}, xml)
    assert_includes xml, "<string>carddav-dev</string>"
  end

  # The name defaults to plain "pro-tacts"; an override (e.g. "pro-tacts
  # (dev)") keeps a dev install distinguishable from production, both in
  # Contacts' account list and in System Settings when both are installed.
  def test_name_defaults_to_pro_tacts
    with_config do
      assert_includes render, "<string>pro-tacts</string>"
    end
  end

  def test_name_can_be_overridden
    with_config("PRO_TACTS_INSTANCE_NAME" => "pro-tacts (dev)") do
      xml = render

      assert_match(%r{<key>CardDAVAccountDescription</key>\s*<string>pro-tacts \(dev\)</string>}, xml)
      assert_includes xml, "<string>pro-tacts (dev) CardDAV</string>"
      assert_includes xml, "<string>example.ts.net</string>"
    end
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

  # An identifier as a render writes one: the prefix, the host's digest,
  # then the unique hex.
  def identifier(hostname, hex = "20260818ab12")
    "#{ProTacts::Profile::IDENTIFIER_PREFIX}.#{ProTacts::Profile.host_digest(hostname)}.#{hex}"
  end

  def payload_identifiers(xml)
    xml.scan(%r{<key>PayloadIdentifier</key>\s*<string>([^<]+)</string>}).flatten
  end

  def test_installed_identifiers_picks_out_pro_tacts_profiles
    list_output = <<~OUTPUT
      _admin-Profiles-1
          identifier: #{identifier("example.ts.net")}

      _admin-Profiles-2
          identifier: com.example.unrelated

      _admin-Profiles-3
          identifier: #{identifier("example.ts.net", "20260818cd34")}
    OUTPUT

    assert_equal [identifier("example.ts.net"), identifier("example.ts.net", "20260818cd34")],
      ProTacts::Profile.installed_identifiers(list_output, hostname: "example.ts.net")
  end

  # The sweep a dev session runs has to leave the profile the deployment
  # installed alone: same prefix, another server.
  def test_installed_identifiers_leaves_profiles_pointing_at_another_host
    list_output = <<~OUTPUT
          identifier: #{identifier("example.ts.net")}
          identifier: #{identifier("localhost")}
    OUTPUT

    assert_equal [identifier("localhost")],
      ProTacts::Profile.installed_identifiers(list_output, hostname: "localhost")
    assert_equal [identifier("example.ts.net")],
      ProTacts::Profile.installed_identifiers(list_output, hostname: "example.ts.net")
  end

  # What the sweep reports as left behind, including the profiles
  # installed before the host was part of the identifier.
  def test_installed_identifiers_without_a_hostname_finds_every_pro_tacts_profile
    list_output = <<~OUTPUT
          identifier: #{identifier("example.ts.net")}
          identifier: #{identifier("localhost")}
          identifier: #{ProTacts::Profile::IDENTIFIER_PREFIX}-20260818cd34
          identifier: com.example.unrelated
    OUTPUT

    assert_equal [
      identifier("example.ts.net"),
      identifier("localhost"),
      "#{ProTacts::Profile::IDENTIFIER_PREFIX}-20260818cd34",
    ], ProTacts::Profile.installed_identifiers(list_output, hostname: nil)
  end

  # A sweep for the host a render points at finds the profile's own
  # identifier and not the account payload's, which carries it as a
  # prefix; a sweep for another host finds neither.
  def test_a_render_is_swept_only_for_the_host_it_points_at
    xml = render(hostname: "example.ts.net")
    list_output = payload_identifiers(xml).map { "    identifier: #{it}\n" }.join

    assert_equal payload_identifiers(xml).reject { it.end_with?(".account") },
      ProTacts::Profile.installed_identifiers(list_output, hostname: "example.ts.net")
    assert_empty ProTacts::Profile.installed_identifiers(list_output, hostname: "localhost")
  end

  # A host differing only in case is the same server, so one sweep takes
  # profiles rendered under either spelling.
  def test_installed_identifiers_reads_the_host_case_insensitively
    list_output = "    identifier: #{identifier("example.ts.net")}\n"

    assert_equal [identifier("example.ts.net")],
      ProTacts::Profile.installed_identifiers(list_output, hostname: "Example.TS.net")
  end

  # A blank host names no server, and the profile it would render points
  # nowhere, so the render is refused instead.
  def test_a_blank_hostname_is_refused
    error = assert_raises(ArgumentError) { render(hostname: "  ") }

    assert_includes error.message, "hostname"
  end

  def test_installed_identifiers_reads_attribute_format_output
    list_output = <<~OUTPUT
      alpha[1] attribute: profileIdentifier: #{identifier("example.ts.net", "20260818155835720a9db")}
      There are 1 user configuration profiles installed for 'alpha'
    OUTPUT

    assert_equal [identifier("example.ts.net", "20260818155835720a9db")],
      ProTacts::Profile.installed_identifiers(list_output, hostname: "example.ts.net")
  end

  def test_installed_identifiers_reads_table_format_output
    list_output = <<~OUTPUT
      Profiles:
          identifier                             display name
          ------------------------------------   --------------
          #{identifier("example.ts.net")}   pro-tacts CardDAV
          com.example.unrelated                  Work
      OUTPUT

    assert_equal [identifier("example.ts.net")],
      ProTacts::Profile.installed_identifiers(list_output, hostname: "example.ts.net")
  end

  def test_installed_identifiers_ignores_longer_identifiers_containing_the_prefix
    list_output = "com.example.#{identifier("example.ts.net")}\n"

    assert_empty ProTacts::Profile.installed_identifiers(list_output, hostname: "example.ts.net")
  end

  def test_installed_identifiers_is_empty_without_ours
    list_output = "  identifier: com.example.unrelated\n"

    assert_empty ProTacts::Profile.installed_identifiers(list_output, hostname: "example.ts.net")
  end

  def test_escapes_xml_in_field_values
    xml = render(hostname: "a&b.ts.net", username: "Ada <& Co>")

    assert_includes xml, "<string>a&amp;b.ts.net</string>"
    refute_includes xml, "<string>a&b.ts.net</string>"
    assert_includes xml, "<string>Ada &lt;&amp; Co&gt;</string>"
    assert_empty Nokogiri::XML(xml).errors
  end
end
