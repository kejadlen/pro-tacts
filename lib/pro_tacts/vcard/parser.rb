
require "strscan"

require "pro_tacts/vcard"

module ProTacts
  class VCard
    # Reads a stored card into VCard::Property and VCard::Line values.
    #
    # Deliberately shallow: a property is a name, its parameters, and the
    # text of its value, and nothing here knows what any of them mean.
    # That is not a shortcut. The stored card is authoritative and this
    # is only a projection of it, so a property this code has never heard
    # of has to travel through untouched, which is what RFC 6352 section
    # 6.3.2.2 requires of a CardDAV server. See
    # docs/plans/2026-08-24-vcard-storage-and-groups.md.
    #
    # The whole reading half of VCard lives here: unfolding, the split
    # into logical lines, and the reads over them. One instance reads one
    # logical line — the scanner is the whole of its state, which is why
    # it is a class and not a handful of functions passing a position
    # between them — and the two class-level reads differ only in
    # strictness. parse raises on a line that will not read, which is
    # what keeps an unparseable card served but unindexed; lines carries
    # the same line with a nil property, which is what lets a rewrite
    # move bytes no line could ever parse out of.
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

      # Every content line in the card, in order. Blank lines are
      # skipped, and BEGIN, VERSION, and END come back like any other
      # property: deciding that a card is well-formed is not this class's
      # job. Raises the error of the first line that will not read, so a
      # caller rescuing ParseError declines the whole card at once.
      #: (String card) -> Array[Property]
      def self.parse(card)
        lines = lines(card)
        error = lines.filter_map { it.error }.first
        raise error if error

        lines.flat_map { it.properties }
      end

      # The card's logical lines, each parsed beside the exact bytes it
      # came from, folds and terminator included — the one walk every
      # read of a card derives from. A line that will not read is a
      # fact about the line, not an error: the error it raised rides on
      # it, and the bytes stay enumerable.
      #: (String card) -> Array[Line]
      def self.lines(card)
        logical_lines(card).map { |logical_line| line_of(logical_line) }
      end

      # VCard.fold's inverse, and the first thing a read does: RFC 2426
      # section 2.6 has a content line unfolded before it is read. It
      # runs over the whole line rather than token by token because a
      # fold can land anywhere in it — Contacts folds at 75 octets
      # without regard for what it splits — so there is no boundary to
      # do it at.
      #: (String line) -> String
      def self.unfold(line)
        line.gsub(FOLD, "")
      end

      # One logical line into a Line: every content line it read, or
      # the error the first failure raised — the prefix that did read
      # is dropped to match parse, which declines a line wholesale by
      # raising. A blank line is neither: no properties, no error.
      #: (String logical_line) -> Line
      def self.line_of(logical_line)
        Line.new(properties: new(logical_line).parse, verbatim: logical_line, error: nil)
      rescue ParseError => error
        Line.new(properties: [], verbatim: logical_line, error:)
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

      # Every content line in this logical line, in order — usually one,
      # though a lone CR can end a content line mid-physical-line, and a
      # blank line has none.
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
