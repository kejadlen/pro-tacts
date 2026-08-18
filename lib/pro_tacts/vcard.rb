# frozen_string_literal: true

require "kdl"

module ProTacts
  # Translates a parsed `contact` KDL node into a vCard 3.0 (RFC 2426).
  #
  # The UID is passed separately because it lives in the filename rather
  # than the file (see docs/plans/2026-01-12-carddav-architecture.md).
  module VCard
    # Folded lines must not exceed 75 octets, excluding the line break
    # (RFC 2426 section 2.6). The octet count, not character count, is
    # what matters: a continuation must never split a multibyte
    # character.
    LINE_LIMIT = 75

    NAME_COMPONENTS = %w[family given additional prefix suffix].freeze
    ADDRESS_PARTS = %w[street city state zip country].freeze

    TEXT_ESCAPES = {
      "\\" => "\\\\",
      ";" => "\\;",
      "," => "\\,",
      "\n" => "\\n"
    }.freeze

    module_function

    def render(contact, uid:)
      name = contact.children.find { it.name == "name" }
      raise ArgumentError, "contact requires a name" unless name

      lines = [
        "BEGIN:VCARD",
        "VERSION:3.0",
        "N:#{structured_name(name)}",
        "FN:#{escape(display_name(name))}",
        *typed_property_lines(contact, "phone", "TEL"),
        *typed_property_lines(contact, "email", "EMAIL"),
        *address_lines(contact),
        "UID:#{escape(uid)}",
        "END:VCARD",
        "", # trailing newline
      ]

      lines.map { fold(it) }.join("\r\n")
    end

    # `name "John Smith"` derives N:Smith;John;;; (last token family, the
    # rest given). Component children override the heuristic entirely:
    # when any of them is present, N is built from exactly those, and
    # every missing component renders empty.
    def structured_name(name)
      overrides = name.children
        .select { NAME_COMPONENTS.include?(it.name) }
        .to_h { [it.name, string_argument(it)] }

      return components(NAME_COMPONENTS.map { overrides.fetch(it, "") }) unless overrides.empty?

      display = display_name(name)
      tokens = display.split
      family = tokens.last || ""
      given = tokens.length > 1 ? tokens.first(tokens.length - 1).join(" ") : ""
      components([family, given, "", "", ""])
    end

    def typed_property_lines(contact, kdl_name, vcard_name)
      contact.children.select { it.name == kdl_name }.map do |node|
        type = node.properties["type"]&.value
        prefix = type ? "#{vcard_name};TYPE=#{type}" : vcard_name
        "#{prefix}:#{escape(string_argument(node))}"
      end
    end

    # ADR's seven components in order: pobox, extended address, street,
    # locality, region, postal code, country. The first two have no KDL
    # counterpart and stay empty.
    def address_lines(contact)
      contact.children.select { it.name == "address" }.map do |node|
        parts = node.children
          .select { ADDRESS_PARTS.include?(it.name) }
          .to_h { [it.name, string_argument(it)] }

        components = ["", "", *ADDRESS_PARTS.map { parts.fetch(it, "") }]
        type = node.properties["type"]&.value
        prefix = type ? "ADR;TYPE=#{type}" : "ADR"
        "#{prefix}:#{components(components)}"
      end
    end

    # Text values escape backslash, the component separator, and the
    # sub-component separator (RFC 2426 section 2.4.2); CRLF and CR are
    # normalized to the `\n` escape because a raw line break would end
    # the property line.
    def escape(text)
      text.gsub(/\r\n|\r/, "\n").gsub(/[\\;,\n]/) { TEXT_ESCAPES.fetch(it) }
    end

    # Escapes each component, then joins with the component separator.
    def components(values)
      values.map { escape(it) }.join(";")
    end

    # Folds a logical line into physical lines of at most LINE_LIMIT
    # octets, each continuation starting with a single space (RFC 2426
    # section 2.6). The walk is character-wise so a multibyte character
    # is never split mid-sequence.
    def fold(line)
      return line if line.bytesize <= LINE_LIMIT

      folded = +""
      width = 0
      line.each_char do |char|
        if width + char.bytesize > LINE_LIMIT
          folded << "\r\n "
          width = 1
        end
        folded << char
        width += char.bytesize
      end
      folded
    end

    def display_name(name)
      argument = name.arguments.first
      raise ArgumentError, "name requires a display string" unless argument

      argument.value.to_s
    end

    def string_argument(node)
      argument = node.arguments.first
      raise ArgumentError, "#{node.name} requires a string argument" if argument.nil?

      argument.value.to_s
    end
  end
end
