
require "strscan"

require "pro_tacts/vcard"

module ProTacts
  module VCard
    # Reads a stored card into VCard::Property values.
    #
    # Deliberately shallow: a property is a name, its parameters, and the
    # text of its value, and nothing here knows what any of them mean.
    # That is not a shortcut. The stored card is authoritative and this
    # is only a projection of it, so a property this code has never heard
    # of has to travel through untouched, which is what RFC 6352 section
    # 6.3.2.2 requires of a CardDAV server. See
    # docs/plans/2026-08-24-vcard-storage-and-groups.md.
    #
    # One instance reads one card. The scanner is the whole of its state,
    # which is why it is a class and not a handful of functions passing
    # a position between them.
    class Parser
      # @rbs @scanner: StringScanner

      # The content line, RFC 2426 section 4:
      #
      #   contentline = [group "."] name *(";" param) ":" value CRLF
      #   group       = 1*(ALPHA / DIGIT / "-")
      #   name        = iana-token / x-name
      #   param       = param-name "=" param-value *("," param-value)
      #
      # A group, a property name, and a parameter name are all the same
      # token. SAFE-CHAR — an unquoted parameter value — is anything but
      # a control character, DQUOTE, ";", ":", or ","; QSAFE-CHAR, inside
      # quotes, allows everything but the controls and DQUOTE;
      # VALUE-CHAR is everything that is not a line break.
      TOKEN = /[A-Za-z0-9-]+/ #: Regexp
      GROUP = /#{TOKEN}(?=\.)/ #: Regexp
      PTEXT = /[^\x00-\x08\x0A-\x1F\x7F";:,]*/ #: Regexp
      QUOTED_STRING = /"([^\x00-\x08\x0A-\x1F\x7F"]*)"/ #: Regexp
      VALUE = /[^\r\n]*/ #: Regexp

      #: (String card) -> Array[Property]
      def self.parse(card)
        new(card).parse
      end

      #: (String card) -> void
      def initialize(card)
        @scanner = StringScanner.new(VCard.unfold(card))
      end

      # Every content line in the card, in order. Blank lines are
      # skipped, and BEGIN, VERSION, and END come back like any other
      # property: deciding that a card is well-formed is not this class's
      # job.
      #: () -> Array[Property]
      def parse
        properties = [] #: Array[Property]
        until @scanner.eos?
          next if @scanner.skip(LINE_BREAK)

          properties << content_line
        end
        properties
      end

      private

      #: () -> Property
      def content_line
        group = @scanner.scan(GROUP)
        @scanner.skip(/\./) if group

        name = @scanner.scan(TOKEN)
        raise ParseError, "expected a property name #{here}" if name.nil?

        parameters = [] #: Array[[String, String]]
        parameters.concat(parameter) while @scanner.skip(/;/)

        raise ParseError, "expected ':' after #{name} #{here}" unless @scanner.skip(/:/)

        value = @scanner.scan(VALUE).to_s
        @scanner.skip(LINE_BREAK)

        Property.new(group:, name:, parameters:, value:)
      end

      # One `;`-delimited parameter, as a pair per value.
      #: () -> Array[[String, String]]
      def parameter
        name = @scanner.scan(TOKEN)
        raise ParseError, "expected a parameter name #{here}" if name.nil?

        # vCard 2.1 let a parameter be written as a bare value with its
        # name left implicit. The 3.0 grammar does not, and guessing
        # which parameter was meant is the kind of invention that loses
        # data.
        raise ParseError, "parameter #{name} has no value #{here}" unless @scanner.skip(/=/)

        values = [parameter_value]
        values << parameter_value while @scanner.skip(/,/)
        values.map {
          # A two-element literal is an Array until something says
          # otherwise, and an inline annotation needs its own line.
          [name, it] #: [String, String]
        }
      end

      # The quotes around a quoted-string are syntax, so what comes back
      # is what they contained.
      #: () -> String
      def parameter_value
        return @scanner[1].to_s if @scanner.scan(QUOTED_STRING)

        @scanner.scan(PTEXT).to_s
      end

      # Where the scan gave up, for the message that says so.
      #: () -> String
      def here
        "at offset #{@scanner.pos}"
      end
    end
  end
end
