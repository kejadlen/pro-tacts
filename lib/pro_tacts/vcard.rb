
require "kdl"

module ProTacts
  # Translates a parsed contact file — a bare KDL document — into a
  # vCard 3.0 (RFC 2426).
  #
  # The UID is passed separately because it lives in the filename rather
  # than the file (see docs/plans/2026-01-12-carddav-architecture.md).
  module VCard
    # Folded lines must not exceed 75 octets, excluding the line break
    # (RFC 2426 section 2.6). The octet count, not character count, is
    # what matters: a continuation must never split a multibyte
    # character.
    LINE_LIMIT = 75

    NAME_COMPONENTS = %w[family given additional prefix suffix].freeze #: Array[String]
    ADDRESS_PARTS = %w[street city state zip country].freeze #: Array[String]
    CONTACT_FIELDS = %w[name phone email address].freeze #: Array[String]

    # Properties each node accepts; anything else is a typo silently
    # dropping data, so it raises.
    ALLOWED_PROPERTIES = {
      "phone" => %w[type],
      "email" => %w[type],
      "address" => %w[type],
    }.freeze #: Hash[String, Array[String]]

    TEXT_ESCAPES = {
      "\\" => "\\\\",
      ";" => "\\;",
      "," => "\\,",
      "\n" => "\\n",
    }.freeze #: Hash[String, String]

    module_function

    #: (KDL::Document document, uid: String) -> String
    def render(document, uid:)
      nodes = document.nodes
      validate_children(nodes, CONTACT_FIELDS, "contact")

      names = nodes.select { it.name == "name" }
      name = names.first
      raise ArgumentError, "contact requires a name" if name.nil?
      raise ArgumentError, "contact takes a single name" if names.length > 1

      n, fn = name_fields(name)

      lines = [
        "BEGIN:VCARD",
        "VERSION:3.0",
        "N:#{components(n)}",
        "FN:#{escape(fn)}",
        *typed_property_lines(nodes, "phone", "TEL"),
        *typed_property_lines(nodes, "email", "EMAIL"),
        *address_lines(nodes),
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
    #: (KDL::Node name) -> [Array[String], String]
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

    #: (Array[KDL::Node] nodes, String kdl_name, String vcard_name) -> Array[String]
    def typed_property_lines(nodes, kdl_name, vcard_name)
      nodes.select { it.name == kdl_name }.map { |node|
        validate_properties(node)
        type = node.properties["type"]&.value
        prefix = type ? "#{vcard_name};TYPE=#{type}" : vcard_name
        "#{prefix}:#{escape(string_argument(node))}"
      }
    end

    # ADR's seven components in order: pobox, extended address, street,
    # locality, region, postal code, country. The first two have no KDL
    # counterpart and stay empty.
    #: (Array[KDL::Node] nodes) -> Array[String]
    def address_lines(nodes)
      nodes.select { it.name == "address" }.map { |node|
        validate_children(node, ADDRESS_PARTS, "address")
        validate_properties(node)
        parts = node.children
          .select { ADDRESS_PARTS.include?(it.name) }
          .to_h do |part|
            # A two-element literal is an Array until something says
            # otherwise, and to_h takes pairs.
            [part.name, string_argument(part)] #: [String, String]
          end

        components = ["", "", *ADDRESS_PARTS.map { parts.fetch(it, "") }]
        type = node.properties["type"]&.value
        prefix = type ? "ADR;TYPE=#{type}" : "ADR"
        "#{prefix}:#{components(components)}"
      }
    end

    # Text values escape backslash, the component separator, and the
    # sub-component separator (RFC 2426 section 2.4.2); CRLF and CR are
    # normalized to the `\n` escape because a raw line break would end
    # the property line.
    #: (String text) -> String
    def escape(text)
      text.gsub(/\r\n|\r/, "\n").gsub(/[\\;,\n]/) { TEXT_ESCAPES.fetch(it) }
    end

    # Escapes each component, then joins with the component separator.
    #: (Array[String] values) -> String
    def components(values)
      values.map { escape(it) }.join(";")
    end

    # Folds a logical line into physical lines of at most LINE_LIMIT
    # octets, each continuation starting with a single space (RFC 2426
    # section 2.6). The walk is character-wise so a multibyte character
    # is never split mid-sequence.
    #: (String line) -> String
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

    #: (KDL::Node node) -> String
    def string_argument(node)
      argument = node.arguments.first
      raise ArgumentError, "#{node.name} requires a string argument" if argument.nil?

      argument.value.to_s
    end

    # Takes a node list or a single node, whose children it walks.
    #: (Array[KDL::Node] | KDL::Node nodes, Array[String] known, String context) -> void
    def validate_children(nodes, known, context)
      unknown = nodes.find { !known.include?(it.name) }
      return if unknown.nil?

      raise ArgumentError, "unknown key in #{context}: #{unknown.name}"
    end

    #: (KDL::Node node) -> void
    def validate_properties(node)
      allowed = ALLOWED_PROPERTIES.fetch(node.name, [])
      unknown = node.properties.keys - allowed
      return if unknown.empty?

      raise ArgumentError, "unknown property on #{node.name}: #{unknown.first}"
    end
  end
end
