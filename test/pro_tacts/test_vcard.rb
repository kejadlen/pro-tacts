
require_relative "../test_helper"

require "kdl"
require "hegel"

require "pro_tacts/vcard"

class VCardTest < Minitest::Test
  include Hegel::Syntax::Methods

  def render(kdl, uid: "test-uid")
    ProTacts::VCard.render(KDL.parse(kdl).nodes.first, uid:)
  end

  ## Unit tests

  def test_simple_contact
    vcard = render(<<~KDL)
      contact {
        name "John Smith"
        phone "+1-555-1234" type="mobile"
        email "john@example.com" type="home"
        address type="home" {
          street "123 Main St"
          city "Springfield"
          state "IL"
          zip "62701"
          country "USA"
        }
      }
    KDL

    assert_equal <<~VCARD.gsub("\n", "\r\n"), vcard
      BEGIN:VCARD
      VERSION:3.0
      N:Smith;John;;;
      FN:John Smith
      TEL;TYPE=mobile:+1-555-1234
      EMAIL;TYPE=home:john@example.com
      ADR;TYPE=home:;;123 Main St;Springfield;IL;62701;USA
      UID:test-uid
      END:VCARD
    VCARD
  end

  def test_single_token_name_gets_empty_given
    vcard = render(<<~KDL)
      contact {
        name "Cher"
      }
    KDL

    assert_includes vcard, "N:Cher;;;;"
  end

  def test_components_only_name
    vcard = render(<<~KDL)
      contact {
        name {
          family "van Beethoven"
          given "Ludwig"
        }
      }
    KDL

    assert_includes vcard, "N:van Beethoven;Ludwig;;;"
    assert_includes vcard, "FN:Ludwig van Beethoven"
  end

  def test_one_component_leaves_the_rest_empty
    vcard = render(<<~KDL)
      contact {
        name {
          family "Bach"
        }
      }
    KDL

    assert_includes vcard, "N:Bach;;;;"
    assert_includes vcard, "FN:Bach"
  end

  def test_fn_joins_components_in_display_order
    vcard = render(<<~KDL)
      contact {
        name {
          prefix "Dr."
          given "John"
          additional "Jacob"
          family "Smith"
          suffix "Jr."
        }
      }
    KDL

    assert_includes vcard, "FN:Dr. John Jacob Smith Jr."
  end

  def test_values_are_escaped
    vcard = render(<<~KDL)
      contact {
        name "semi;colon, comma back\\\\slash"
      }
    KDL

    assert_includes vcard, "FN:semi\\;colon\\, comma back\\\\slash"
  end

  def test_newlines_escape_as_literal_n
    vcard = render(<<~KDL)
      contact {
        name "two\\nlines"
      }
    KDL

    assert_includes vcard, "FN:two\\nlines"
  end

  def test_long_lines_fold_and_unfold_intact
    vcard = render(<<~KDL)
      contact {
        name "#{"x" * 30}#{("é" * 60)}"
      }
    KDL

    physical = vcard.split("\r\n")
    assert_operator physical.length, :>, 1, "expected folding"
    physical.each do
      assert_operator it.bytesize, :<=, 75
    end

    logical = unfold(physical)
    assert_equal "FN:#{"x" * 30}#{("é" * 60)}", logical.find { it.start_with?("FN:") }
  end

  def test_properties_without_type
    vcard = render(<<~KDL)
      contact {
        name "John"
        phone "+1-555-1234"
        address {
          street "123 Main St"
        }
      }
    KDL

    assert_includes vcard, "TEL:+1-555-1234"
    assert_includes vcard, "ADR:;;123 Main St;;;;"
  end

  def test_order_is_preserved
    vcard = render(<<~KDL)
      contact {
        name "John"
        phone "+1-555-1"
        phone "+1-555-2"
        email "a@example.com"
        phone "+1-555-3"
      }
    KDL

    lines = vcard.split("\r\n")
    assert_equal %w[+1-555-1 +1-555-2 +1-555-3], lines.grep(/\ATEL/).map { it.split(":", 2).last }
    assert_equal 1, lines.grep(/\AEMAIL/).length
  end

  def test_missing_name_raises
    error = assert_raises(ArgumentError) do
      render(<<~KDL)
        contact {
          phone "+1-555-1234"
        }
      KDL
    end

    assert_equal "contact requires a name", error.message
  end

  def test_name_with_both_display_and_components_raises
    error = assert_raises(ArgumentError) do
      render(<<~KDL)
        contact {
          name "Ludwig van Beethoven" {
            family "van Beethoven"
          }
        }
      KDL
    end

    assert_equal "name takes a display string or component children, not both", error.message
  end

  def test_name_with_neither_display_nor_components_raises
    error = assert_raises(ArgumentError) do
      render(<<~KDL)
        contact {
          name
        }
      KDL
    end

    assert_equal "name requires a display string or component children", error.message
  end

  def test_all_empty_components_raise
    error = assert_raises(ArgumentError) do
      render(<<~KDL)
        contact {
          name {
            family ""
          }
        }
      KDL
    end

    assert_equal "name components cannot all be empty", error.message
  end

  def test_property_without_value_raises
    error = assert_raises(ArgumentError) do
      render(<<~KDL)
        contact {
          name "John"
          phone type="mobile"
        }
      KDL
    end

    assert_equal "phone requires a string argument", error.message
  end

  def test_unknown_contact_key_raises
    error = assert_raises(ArgumentError) do
      render(<<~KDL)
        contact {
          name "John"
          emial "john@example.com"
        }
      KDL
    end

    assert_equal "unknown key in contact: emial", error.message
  end

  def test_unknown_name_component_raises
    error = assert_raises(ArgumentError) do
      render(<<~KDL)
        contact {
          name {
            family "Smith"
            middle "Q"
          }
        }
      KDL
    end

    assert_equal "unknown key in name: middle", error.message
  end

  def test_unknown_address_key_raises
    error = assert_raises(ArgumentError) do
      render(<<~KDL)
        contact {
          name "John"
          address {
            street "123 Main St"
            province "IL"
          }
        }
      KDL
    end

    assert_equal "unknown key in address: province", error.message
  end

  def test_unknown_property_raises
    error = assert_raises(ArgumentError) do
      render(<<~KDL)
        contact {
          name "John"
          phone "+1-555-1234" tpye="mobile"
        }
      KDL
    end

    assert_equal "unknown property on phone: tpye", error.message
  end

  ## Property tests
  #
  # The oracles are deliberately independent of the renderer: an
  # unfold/unescape/parse implementation written here in the test, so a
  # renderer bug cannot hide behind shared code.

  # The renderer normalizes CRLF and CR to \n before escaping, so the
  # oracle applies the same normalization before comparing.
  def normalize(text)
    text.gsub(/\r\n|\r/, "\n")
  end

  # Serializes a string as a KDL quoted string: backslash, quote, and
  # the line breaks are escaped (CRLF and CR normalize to a single \n,
  # matching the renderer's documented normalization), and the C0/DEL
  # control characters that KDL forbids raw inside a string become \u
  # escapes.
  def kdl_string(text)
    escaped = normalize(text).chars.map { |char|
      case char
      when "\\" then "\\\\"
      when '"' then '\\"'
      when "\n", "\r" then "\\n"
      when /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/ then format('\u{%02x}', char.ord)
      else char
      end
    }.join
    "\"#{escaped}\""
  end

  # Joins physical lines back into logical ones: a line starting with a
  # single space continues the previous one. slice_when starts a new
  # group wherever the next line is not a continuation.
  def logical_lines(vcard)
    unfold(vcard.split("\r\n"))
  end

  def unfold(lines)
    lines.slice_when { |_line, next_line| !next_line.start_with?(" ") }
      .map { |group| group.first + group.drop(1).map { it[1..] }.join }
  end

  # Reverses RFC 2426 section 2.4.2 escaping.
  def unescape(text)
    text.gsub(/\\(.)/) do
      case Regexp.last_match(1)
      when "n" then "\n"
      when "\\", ";", "," then Regexp.last_match(1)
      else raise "unknown vCard escape: \\#{Regexp.last_match(1)}"
      end
    end
  end

  # Splits on a separator that is not itself escaped.
  def split_unescaped(text, separator)
    parts = [+""]
    index = 0
    while index < text.length
      if text[index] == "\\" && index + 1 < text.length
        parts.last << text[index, 2]
        index += 2
      elsif text[index] == separator
        parts << +""
        index += 1
      else
        parts.last << text[index]
        index += 1
      end
    end
    parts
  end

  # Minimal independent vCard parser: returns the fields the renderer
  # produces, with values unescaped and components split.
  def parse_vcard(vcard)
    fields = {n: [], tel: [], email: [], adr: []}
    logical_lines(vcard).each do |line|
      head, value = line.split(":", 2)
      name, raw_params = head.split(";", 2)
      type = raw_params&.then { it[/\ATYPE=(.*)\z/, 1] }
      case name
      when "FN" then fields[:fn] = unescape(value)
      when "UID" then fields[:uid] = unescape(value)
      when "N", "ADR"
        components = split_unescaped(value, ";").map { unescape(it) }
        fields[:n] = components if name == "N"
        fields[:adr] << [components, type] if name == "ADR"
      when "TEL" then fields[:tel] << [unescape(value), type]
      when "EMAIL" then fields[:email] << [unescape(value), type]
      end
    end
    fields
  end

  # The expected FN: the display string for a display-only name, or the
  # components joined in display order for a components-only name.
  # Values are normalized (CR/CRLF → LF) the way the renderer's escape
  # step normalizes them before writing.
  def expected_fn(display, components)
    return normalize(display) if components.values.none?

    %w[prefix given additional family suffix]
      .map { normalize(components.fetch(it.to_sym) || "") }.reject(&:empty?).join(" ")
  end

  # The display-name heuristic, reimplemented: last token family, the
  # rest given.
  def derived_n(display)
    tokens = normalize(display).split
    family = tokens.last || ""
    given = tokens.length > 1 ? tokens.first(tokens.length - 1).join(" ") : ""
    [family, given, "", "", ""]
  end

  # Builds the KDL source for a contact from generated field data.
  def kdl_contact(display:, family: nil, given: nil, additional: nil, prefix: nil, suffix: nil,
    phones: [], emails: [], addresses: [])
    name_children = {family:, given:, additional:, prefix:, suffix:}
      .filter_map { |part, value| "#{part} #{kdl_string(value)}" unless value.nil? }

    contact = +"contact {\n"
    if name_children.empty?
      contact << "  name #{kdl_string(display)}\n"
    else
      contact << "  name {\n#{name_children.map { "    #{it}\n" }.join}  }\n"
    end
    phones.each do |value, type|
      suffix = type ? " type=\"#{type}\"" : ""
      contact << "  phone #{kdl_string(value)}#{suffix}\n"
    end
    emails.each do |value, type|
      suffix = type ? " type=\"#{type}\"" : ""
      contact << "  email #{kdl_string(value)}#{suffix}\n"
    end
    addresses.each do |parts, type|
      suffix = type ? " type=\"#{type}\"" : ""
      inner = parts.map { |part, value| "    #{part} #{kdl_string(value)}\n" }.join
      contact << "  address#{suffix} {\n#{inner}  }\n"
    end
    contact << "}\n"
  end

  def test_escaped_fn_survives_round_trip
    Hegel.test do |tc|
      display = tc.draw(text(min_size: 1, max_size: 200))
      vcard = ProTacts::VCard.render(
        KDL.parse(kdl_contact(display:)).nodes.first,
        uid: "uid"
      )

      fn = parse_vcard(vcard).fetch(:fn)
      raise "FN did not survive escaping" unless fn == normalize(display)
    end
  end

  def test_physical_lines_fit_in_75_octets
    Hegel.test do |tc|
      display = tc.draw(text(min_size: 1, max_size: 300))
      uid = tc.draw(text(min_size: 1, max_size: 300))
      vcard = ProTacts::VCard.render(
        KDL.parse(kdl_contact(display:)).nodes.first,
        uid:
      )

      physical = vcard.split("\r\n")
      too_long = physical.find { it.bytesize > 75 }
      raise "line exceeds 75 octets: #{too_long&.bytesize}" if too_long
      raise "folded away the terminators" unless physical.first == "BEGIN:VCARD" && physical.last == "END:VCARD"
      raise "UID did not survive folding" unless parse_vcard(vcard).fetch(:uid) == normalize(uid)
    end
  end

  def test_contact_fields_survive_round_trip
    type = from_regex("[a-zA-Z0-9]{1,10}", fullmatch: true)
    Hegel.test do |tc|
      display = tc.draw(text(max_size: 30))
      components = {
        family: tc.draw(optional(text(max_size: 20))),
        given: tc.draw(optional(text(max_size: 20))),
        additional: tc.draw(optional(text(max_size: 20))),
        prefix: tc.draw(optional(text(max_size: 20))),
        suffix: tc.draw(optional(text(max_size: 20))),
      }
      phones = tc.draw(arrays(tuples(text(max_size: 30), optional(type)), max_size: 5))
      emails = tc.draw(arrays(tuples(text(max_size: 30), optional(type)), max_size: 5))
      addresses = tc.draw(arrays(
        tuples(
          text(max_size: 20), text(max_size: 20), text(max_size: 20),
          text(max_size: 20), text(max_size: 20), optional(type),
        ),
        max_size: 3,
      ))
      uid = tc.draw(uuids)
      # The renderer rejects a components-only name whose parts are all
      # empty (FN would have nothing to draw from), so the generator
      # honors that contract.
      tc.assume(components.values.any? { !it.nil? && !it.empty? })

      kdl = kdl_contact(
        display:,
        **components,
        phones:,
        emails:,
        addresses: addresses.map { |street, city, state, zip, country, addr_type|
          [%w[street city state zip country].zip([street, city, state, zip, country]).to_h, addr_type]
        }
      )
      vcard = ProTacts::VCard.render(KDL.parse(kdl).nodes.first, uid:)
      parsed = parse_vcard(vcard)

      raise "FN mismatch" unless parsed.fetch(:fn) == expected_fn(display, components)
      raise "UID mismatch" unless parsed.fetch(:uid) == uid

      expected_n = if components.values.none?
        derived_n(display)
      else
        %i[family given additional prefix suffix].map { normalize(components.fetch(it) || "") }
      end
      raise "N mismatch" unless parsed.fetch(:n) == expected_n

      expected_phones = phones.map { |value, phone_type| [normalize(value), phone_type] }
      raise "TEL mismatch" unless parsed.fetch(:tel) == expected_phones

      expected_emails = emails.map { |value, email_type| [normalize(value), email_type] }
      raise "EMAIL mismatch" unless parsed.fetch(:email) == expected_emails

      raise "ADR count mismatch" unless parsed.fetch(:adr).length == addresses.length
      addresses.zip(parsed.fetch(:adr)).each do |(street, city, state, zip, country, addr_type), (got, got_type)|
        raise "ADR components mismatch" unless got == ["", "", normalize(street), normalize(city), normalize(state), normalize(zip), normalize(country)]
        raise "ADR type mismatch" unless got_type == addr_type
      end
    end
  end
end
