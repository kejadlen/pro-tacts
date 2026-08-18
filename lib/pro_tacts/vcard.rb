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
    CONTACT_FIELDS = %w[name phone email address].freeze

    # Properties each node accepts; anything else is a typo silently
    # dropping data, so it raises.
    ALLOWED_PROPERTIES = {
      "phone" => %w[type],
      "email" => %w[type],
      "address" => %w[type]
    }.freeze

    TEXT_ESCAPES = {
      "\\" => "\\\\",
      ";" => "\\;",
      "," => "\\,",
      "\n" => "\\n"
    }.freeze

    module_function

    def render(contact, uid:)
      validate_children(contact, CONTACT_FIELDS, "contact")
      validate_properties(contact)

      name = contact.children.find { it.name == "name" }
      raise ArgumentError, "contact requires a name" unless name

      n, fn = name_fields(name)

      lines = [
        "BEGIN:VCARD",
        "VERSION:3.0",
        "N:#{components(n)}",
        "FN:#{escape(fn)}",
        *typed_property_lines(contact, "phone", "TEL"),
        *typed_property_lines(contact, "email", "EMAIL"),
        *address_lines(contact),
        "UID:#{escape(uid)}",
        "END:VCARD",
        "", # trailing newline
      ]

      lines.map { fold(it) }.join("\r\n")
    end

    # A name is either a display string — `name "John Smith"`, where N
    # is derived (last token family, the rest given) and FN is the string
    # itself — or component children, where N is exactly those components
    # and FN is derived from them (prefix, given, additional, family,
    # suffix; empty parts skipped). Providing both is an error: they are
    # two spellings of the same truth, and silently preferring one would
    # hide the disagreement. Returns [N components, FN].
    def name_fields(name)
      validate_children(name, NAME_COMPONENTS, "name")
      validate_properties(name)

      overrides = name.children.select { NAME_COMPONENTS.include?(it.name) }

      case [name.arguments, overrides]
      in [[], []]
        raise ArgumentError, "name requires a display string or component children"
      in [Array[_, *], Array[_, *]]
        raise ArgumentError, "name takes a display string or component children, not both"
      in [Array[_, *], []]
        display = name.arguments.first.value.to_s
        tokens = display.split
        family = tokens.last || ""
        given = tokens.length > 1 ? tokens.first(tokens.length - 1).join(" ") : ""
        [[family, given, "", "", ""], display]
      in [[], _]
        values = overrides.to_h { [it.name, string_argument(it)] }
        n = NAME_COMPONENTS.map { values.fetch(it, "") }
        fn = %w[prefix given additional family suffix]
          .map { values.fetch(it, "") }
          .reject(&:empty?)
          .join(" ")
        # FN is required (RFC 2426 section 4.1.1), so components that are
        # all empty have nothing to render it from.
        raise ArgumentError, "name components cannot all be empty" if fn.empty?

        [n, fn]
      end
    end

    def typed_property_lines(contact, kdl_name, vcard_name)
      contact.children.select { it.name == kdl_name }.map do |node|
        validate_properties(node)
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
        validate_children(node, ADDRESS_PARTS, "address")
        validate_properties(node)
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
      line.chars.each do |char|
        if width + char.bytesize > LINE_LIMIT
          folded << "\r\n "
          width = 1
        end
        folded << char
        width += char.bytesize
      end
      folded
    end

    def string_argument(node)
      argument = node.arguments.first
      raise ArgumentError, "#{node.name} requires a string argument" if argument.nil?

      argument.value.to_s
    end

    def validate_children(node, known, context)
      unknown = node.children.reject { known.include?(it.name) }
      return if unknown.empty?

      raise ArgumentError, "unknown key in #{context}: #{unknown.first.name}"
    end

    def validate_properties(node)
      allowed = ALLOWED_PROPERTIES.fetch(node.name, [])
      unknown = node.properties.keys - allowed
      return if unknown.empty?

      raise ArgumentError, "unknown property on #{node.name}: #{unknown.first}"
    end
  end
end
