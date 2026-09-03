
require "strscan"

require "pro_tacts/vcard"

module ProTacts
  class VCard
    # Reads a card's bytes into Lines.
    #
    # Deliberately shallow: a property is a name, its parameters, and the
    # text of its value, and nothing here knows what any of them mean.
    # That is not a shortcut. The stored card is authoritative and this
    # is only a projection of it, so a property this code has never heard
    # of has to travel through untouched, which is what RFC 6352 section
    # 6.3.2.2 requires of a CardDAV server. See
    # docs/plans/2026-08-24-vcard-storage-and-groups.md.
    #
    # The whole reading half of VCard lives here — unfolding, the split
    # into logical lines, the reads over them, and the values they come
    # back as — and it has one entry point: lines. One instance reads
    # one logical line; the scanner is the whole of its state, which is
    # why it is a class and not a handful of functions passing a
    # position between them.
    #
    # A line that will not read is a Line like any other, carrying the
    # error rather than raising it, and no read here raises on a card's
    # behalf. Nothing above handles one either: VCard and Contact answer
    # from the lines that read, the index holds what this server
    # understood, and a rewrite moves the bytes regardless. The error
    # rides along for one reader, ProTacts::Web, which reports a broken
    # assumption at the arrival that carried it.
    class Parser
      # @rbs @scanner: StringScanner

      # A line whose bytes are not a content line at all. Never raised
      # past #lines, which catches it and hands it back on the Line it
      # happened to: what a line failing to read costs is that line's
      # index rows, and the card is served from its bytes regardless.
      class ParseError < StandardError; end

      # Something this parser was built to assume it would never read.
      # Not a judgment on the card: the assumptions are about macOS
      # Contacts, the only client this address book serves
      # (test/fixtures/macos-exchange is the evidence for each), and a
      # card can break one while being a perfectly good vCard. Raising
      # is how the assumption gets checked instead of merely held.
      #
      # A ParseError so it rides the same rails as any line that will
      # not read — the bytes are still served, index rows are what is
      # lost — and its own class so ProTacts::Web can report it at the
      # arrival, a wrong assumption being news rather than ordinary bad
      # input.
      class BrokenAssumption < ParseError; end

      # One parsed content line.
      #
      # `parameters` is a list of name-and-value pairs rather than a hash
      # because a parameter can repeat, and RFC 2426 section 3.3.1 makes
      # `TYPE=work;TYPE=voice` and `TYPE=work,voice` two spellings of the
      # same thing — both arrive here as two pairs.
      #
      # `value` is the value's text, unfolded and otherwise exactly as it
      # was stored, still escaped. Unescaping it and splitting it on the
      # component separator are per-property semantics, and this layer has
      # none.
      #
      # The signature lives in sig/pro_tacts/vcard/parser.rbs: a Data
      # class has no constant super class for the inline syntax to read.
      # @rbs skip
      Property = Data.define(:group, :name, :parameters, :value)

      # One logical line of a card, parsed beside the exact bytes that
      # carried it: `property` is the content line it read, nil when it
      # read none (a blank line, or one that would not read), `error` the
      # ParseError the failure raised, nil when it read, and `verbatim`
      # the line itself, folds and terminator included, so what moves
      # between cards moves unchanged.
      #
      # One property, not a list of them: a logical line can only hold a
      # second content line when a bare CR ends the first, and that is
      # refused outright (BrokenAssumption). That is what lets a caller
      # move a line's bytes knowing it moves exactly one property.
      #
      # The signature lives in sig/pro_tacts/vcard/parser.rbs with
      # Property's.
      # @rbs skip
      Line = Data.define(:property, :verbatim, :error)

      # Reopened rather than defined in the block above: steep reads a
      # define block's self as this class's, not the constant's, so the
      # methods could not live there.
      class Line
        # Whether this line names the property, a group prefix
        # (`item1.BDAY`) counting as naming it. Asked of the line rather
        # than the property because a line that will not parse still has
        # a name in it.
        #: (String name) -> bool
        def names?(name)
          verbatim.match?(/\A(?:[A-Za-z0-9-]+\.)?#{Regexp.escape(name)}[;:]/i)
        end

        # Whether this line broke one of the parser's assumptions rather
        # than merely failing to read. Asked here so no caller has to
        # know the error taxonomy to tell the two apart.
        #: () -> bool
        def broke_assumption? = error.is_a?(BrokenAssumption)
      end

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

      # A bare CR is not a line break in the grammar, but it ends a value
      # and has to end a line here too: without it the scanner would sit
      # on one forever, because no token can consume it.
      LINE_BREAK = /\r\n|[\r\n]/ #: Regexp

      # Reads like an alternation-precedence bug and is not: Ruby wraps
      # an interpolated Regexp in a non-capturing group, so this is
      # `(?:\r\n|[\r\n])[ \t]` rather than `\r\n` or `[\r\n][ \t]`.
      FOLD = /#{LINE_BREAK}[ \t]/ #: Regexp

      # A physical line that continues the one above it (RFC 2426 section
      # 2.6 folding).
      CONTINUATION = /\A[ \t]/ #: Regexp

      # The card's logical lines, each parsed beside the exact bytes it
      # came from, folds and terminator included — the one walk every
      # read of a card derives from. Blank lines are lines, and BEGIN,
      # VERSION, and END read like any other property: deciding that a
      # card is well-formed is not this class's job. A line that will
      # not read is a fact about the line, not an error: the error it
      # raised rides on it, and the bytes stay enumerable.
      #: (String card) -> Array[Line]
      def self.lines(card)
        logical_lines(card).map { |logical_line| line_of(logical_line) }
      end

      # VCard.fold's inverse, and the first thing a read does: RFC 2426
      # section 2.6 has a content line unfolded before it is read. It
      # runs over the whole line rather than token by token because the
      # RFC puts no constraint on where a fold lands — mid-token and
      # mid-escape included — so there is no boundary to do it at.
      #
      # The recorded macOS session folds nothing: it sent a 443-octet
      # X-ADDRESSING-GRAMMAR line and an 81-octet ADR unbroken, both
      # past the 75-octet limit, with no continuation in the card
      # (test/fixtures/macos-exchange/10-put-contact-edit). That is one
      # capture of one card, and the PHOTO bodies that would settle it
      # went unpromoted, so this stays general rather than becoming
      # another macOS assumption.
      #: (String line) -> String
      def self.unfold(line)
        line.gsub(FOLD, "")
      end

      # One logical line into a Line: the content line it read, or the
      # error the failure raised. A blank line is neither: no property,
      # no error.
      #: (String logical_line) -> Line
      def self.line_of(logical_line)
        Line.new(property: new(logical_line).parse, verbatim: logical_line, error: nil)
      rescue ParseError => error
        Line.new(property: nil, verbatim: logical_line, error:)
      end

      # The card's logical lines: a physical line and the continuations
      # folded under it, kept together because a property and its fold
      # are one unit (RFC 2426 section 2.6). Slicing before each
      # non-continuation, rather than chunking, is what attaches a
      # continuation to the line above it. The empty string the
      # byte-level split leaves behind is not a line — dropping it loses
      # nothing, an empty group joining to nothing.
      #: (String card) -> Array[String]
      def self.logical_lines(card)
        physical_lines(card)
          .slice_when { |_line, next_line| !next_line.match?(CONTINUATION) }
          .map(&:join)
          .reject { it == "" }
      end

      # Physical lines with their terminators attached, so the split
      # cannot lose or normalize a line break.
      #: (String card) -> Array[String]
      def self.physical_lines(card)
        card.split(/(?<=\n)/, -1)
      end

      private_class_method :line_of, :logical_lines, :physical_lines

      #: (String logical_line) -> void
      def initialize(logical_line)
        @scanner = StringScanner.new(self.class.unfold(logical_line))
      end

      # The one content line this logical line carries, or nil when it
      # carries none — a blank line reads as nothing.
      #
      # A second content line means a bare CR ended the first (see
      # LINE_BREAK), and that is refused rather than read: it is a line
      # ending no recorded macOS session sends, and reading it would
      # leave a property whose bytes cannot move without taking another
      # property's along.
      #: () -> Property?
      def parse
        nil while @scanner.skip(LINE_BREAK)
        return nil if @scanner.eos?

        property = content_line
        return property if @scanner.eos?

        raise BrokenAssumption, "a bare CR packed a second content line into one line #{here}"
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
