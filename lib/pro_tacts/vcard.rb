module ProTacts
  # A card, read once: the parsed properties beside the exact bytes
  # they came from, so a caller asks questions of either without
  # re-parsing, and moves a property without a byte around it moving
  # too. #lines walks the card once into Line values — a logical line's
  # property beside the exact bytes that carried it — and is the
  # enumeration the questions that move bytes are asked over;
  # #properties folds the same walk down to structure, and #insert
  # puts lines back in. vCard 3.0 (RFC 2426): escape and fold, the
  # writer's half, are here; Parser owns the reading half, down to
  # the line split. The walk is lazy for the same reason Contact's
  # parse is: the byte-moving paths never read structure.
  class VCard
    # Folded lines must not exceed 75 octets, excluding the line break
    # (RFC 2426 section 2.6). The octet count, not character count, is
    # what matters: a continuation must never split a multibyte
    # character.
    LINE_LIMIT = 75 #: Integer

    TEXT_ESCAPES = {
      "\\" => "\\\\",
      ";" => "\\;",
      "," => "\\,",
      "\n" => "\\n",
    }.freeze #: Hash[String, String]

    # The line inserted lines go immediately before, so a property
    # lands inside the envelope however bare the card is.
    END_LINE = /\AEND:VCARD/i #: Regexp

    # A card whose bytes are not a vCard at all. Callers are expected to
    # carry on serving the card: failing to parse costs an index entry,
    # not the contact.
    class ParseError < StandardError; end

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
    # The signature lives in sig/pro_tacts/vcard.rbs: a Data class has no
    # constant super class for the inline syntax to read.
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
    # second content line when a bare CR ends the first, and Parser
    # refuses that outright (Parser::BrokenAssumption). That is what
    # lets a caller move a line's bytes knowing it moves exactly one
    # property.
    #
    # The signature lives in sig/pro_tacts/vcard.rbs with Property's.
    # @rbs skip
    Line = Data.define(:property, :verbatim, :error)

    # Reopened rather than defined in the block above: steep reads a
    # define block's self as this class's, not the constant's, so the
    # method could not live there.
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
      def broke_assumption?
        error.is_a?(Parser::BrokenAssumption)
      end
    end

    # Text values escape backslash, the component separator, and the
    # sub-component separator (RFC 2426 section 2.4.2); CRLF and CR are
    # normalized to the `\n` escape because a raw line break would end
    # the property line.
    #: (String text) -> String
    def self.escape(text)
      text.gsub(/\r\n|\r/, "\n").gsub(/[\\;,\n]/) { TEXT_ESCAPES.fetch(it) }
    end

    # escape's inverse: unescapes backslash, the component separators, and
    # the `\n` line-break escape (RFC 2426 section 2.4.2). Nothing that
    # serves a card needs this — a served card is the stored bytes going
    # out unparsed — but a view that displays a structured value (an
    # admin screen, not this server's CardDAV responses) has to undo the
    # escaping or show the reader literal backslashes.
    #: (String text) -> String
    def self.unescape(text)
      text.gsub(/\\[\\;,n]/) { it == "\\n" ? "\n" : it[1..].to_s }
    end

    # Splits a structured value's ";"-delimited components (RFC 2426
    # section 3.2.1, e.g. ADR and N) without breaking on an escaped
    # "\;", and unescapes each component in the same pass.
    #: (String value) -> Array[String]
    def self.split_components(value)
      value.split(/(?<!\\);/, -1).map { unescape(it) }
    end

    # Folds a logical line into physical lines of at most LINE_LIMIT
    # octets, each continuation starting with a single space (RFC 2426
    # section 2.6). The walk is character-wise so a multibyte character
    # is never split mid-sequence.
    #: (String line) -> String
    def self.fold(line)
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

    # A card is made of UTF-8 text, and refuses to be made of anything
    # else: bytes that are not valid UTF-8 raise here, at the boundary,
    # rather than leaking an ArgumentError out of whatever regex first
    # trips over them. A PUT gates this with its own 412 first, and the
    # store's bind holds the same line again below the card.
    #: (String bytes) -> void
    def initialize(bytes)
      raise ArgumentError, "not valid UTF-8: a card is text" unless bytes.valid_encoding?

      @bytes = bytes
    end

    # The card's properties, folded off the same single walk #lines is
    # and parsed once on the first structured read. Nil when any line
    # would not read — a caller is expected to carry on serving the
    # bytes (ParseError's rule, held one level up).
    #: () -> Array[Property]?
    def properties
      return @properties if defined?(@properties)

      @properties = lines.any? { it.error } ? nil : lines.filter_map { it.property }
    end

    # Whether the parsed properties carry the envelope RFC 2426 section
    # 4 requires of a card: BEGIN:VCARD first, END:VCARD last, and a
    # VERSION in between. Deciding that is deliberately not the
    # parser's job — it reads lines without judging the card — so it
    # lives here, where a caller that has to decide (a PUT) can ask.
    # The VERSION's value is not judged: any version is stored verbatim,
    # and this only decides whether there is a card at all.
    #: () -> bool
    def card?
      parsed = properties
      return false if parsed.nil? || parsed.empty?

      first, last = parsed.first, parsed.last
      first.name.casecmp?("BEGIN") && first.value.casecmp?("VCARD") &&
        last.name.casecmp?("END") && last.value.casecmp?("VCARD") &&
        parsed.any? { it.name.casecmp?("VERSION") }
    end

    # The value of the card's UID property, if it carries one. Names
    # compare without case, as the index's NOCASE collation already
    # assumes for them.
    #: () -> String?
    def uid
      parsed = properties
      parsed && parsed.find { it.name.casecmp?("UID") }&.value
    end

    # The parser assumptions this card broke — the errors themselves,
    # so a caller reporting them can say what was assumed and where.
    # Empty for a card that reads, and for one that merely will not:
    # a broken assumption is news about this server, ordinary bad
    # input is not (Parser::BrokenAssumption). Deciding what to do
    # about it is the caller's — reporting on every parse would fire
    # on every read of the card, not once on its arrival.
    #: () -> Array[Parser::BrokenAssumption]
    def broken_assumptions
      lines.filter_map { |line|
        error = line.error
        error if error.is_a?(Parser::BrokenAssumption)
      }
    end

    # The card's logical lines, each parsed beside its verbatim bytes —
    # the enumeration the questions that move bytes are asked over. A
    # continuation travels with its line, terminators attached, so no
    # line's bytes are lost or normalized on the way through (RFC 2426
    # section 2.6 folding).
    #: () -> Array[Line]
    def lines
      return @lines if defined?(@lines)

      @lines = Parser.lines(@bytes)
    end

    # Lines into the card immediately before END:VCARD. A line with no
    # terminator of its own takes the END line's, so a card stays
    # single-convention; a terminated line keeps its own, folds and
    # all. With no END to anchor to there is no envelope worth
    # respecting, and the lines are appended with CRLF.
    #: (Array[String] lines) -> String
    def insert(lines)
      return @bytes if lines.empty?

      physical = physical_lines
      index = physical.rindex { it.match?(END_LINE) }
      if index
        terminator = terminator_of(physical.fetch(index))
        physical.insert(index, *lines.map { it.end_with?("\n") ? it : it + terminator })
        physical.join
      else
        @bytes + lines.map { it.end_with?("\n") ? it : it + "\r\n" }.join
      end
    end

    private

    # Physical lines with their terminators attached, so surgery on them
    # cannot lose or normalize a line break.
    #: () -> Array[String]
    def physical_lines
      @bytes.split(/(?<=\n)/, -1)
    end

    # The line break a line ends with, for the line inserted beside it
    # to match. CRLF when it has none, being the grammar's own.
    #: (String line) -> String
    def terminator_of(line)
      line[/\r?\n\z/] || "\r\n"
    end
  end
end
