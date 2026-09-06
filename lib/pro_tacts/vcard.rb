module ProTacts
  # A card, read once: the parsed properties beside the exact bytes
  # they came from, so a caller asks questions of either without
  # re-parsing, and moves a property without a byte around it moving
  # too. #lines is Parser's walk of the card, memoized — a
  # Parser::Line per logical line — and is the enumeration the
  # questions that move bytes are asked over; #properties folds the
  # same walk down to structure, and #insert puts lines back in. vCard
  # 3.0 (RFC 2426): escape and fold, the writer's half, are here;
  # Parser owns the reading half, down to the line split and the
  # values it comes back as. The walk is lazy for the same reason
  # Contact's parse is: the byte-moving paths never read structure.
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
    # "\;" — the writer's half of the split, over the still-escaped
    # value: a splice replaces some components and joins the rest back
    # byte for byte, where unescape-then-re-escape is not byte-stable
    # (#unescape leaves an unrecognized escape like "\x" alone, and
    # #escape would double its backslash).
    #: (String value) -> Array[String]
    def self.split_raw_components(value)
      value.split(/(?<!\\);/, -1)
    end

    # split_raw_components with each component unescaped — the
    # reader's half, for a caller asking what the components say
    # rather than splicing them.
    #: (String value) -> Array[String]
    def self.split_components(value)
      split_raw_components(value).map { unescape(it) }
    end

    # A property's content line up to its colon — group, name,
    # parameters — re-rendered, for an edit that swaps the value and
    # keeps the header: a phone's line (say) carries parameters no
    # form models, and macOS writes three TYPE parameters on one TEL
    # (test/fixtures/cards/emoji.vcf), so a save that rebuilt the
    # header from the form's fields would drop what the form never
    # showed. The param values render as the grammar's own two
    # spellings allow: bare when every char is PTEXT, quoted
    # otherwise — the same line the parser read, either way. A folded
    # header re-renders unfolded, a normalization a save applies only
    # to the line it was asked to change.
    #: (Parser::Property property) -> String
    def self.header_of(property)
      prefix = property.group ? "#{property.group}." : ""
      parameters = property.parameters.map do |name, value|
        bare = /\A#{Parser::PTEXT}\z/.match?(value)
        ";#{name}=#{bare ? value : "\"#{value}\""}"
      end
      "#{prefix}#{property.name}#{parameters.join}:"
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
    # trips over them. Raising rather than answering, because no caller
    # is meant to be asking — a card's bytes come from a column that can
    # hold nothing else or from a body already decoded, and whether some
    # bytes are text at all is that decode's question, settled before
    # anything here sees them (ProTacts::Web's write_card). This is the
    # assertion under those callers, not a check any of them makes; the
    # store's bind holds the same line a third time below the card.
    #: (String bytes) -> void
    def initialize(bytes)
      raise ArgumentError, "not valid UTF-8: a card is text" unless bytes.valid_encoding?

      @bytes = bytes
    end

    # The card's properties, folded off the same single walk #lines is
    # and parsed once on the first structured read: every line that
    # read, in order. A line that would not read is not this class's
    # problem — the bytes are served either way, and a caller that
    # cannot act on a partial reading asks #lines whether any line was
    # unreadable before asking anything here.
    #: () -> Array[Parser::Property]
    def properties
      return @properties if defined?(@properties)

      @properties = lines.filter_map { it.property }
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
      first, last = properties.first, properties.last
      return false if first.nil? || last.nil?

      first.name.casecmp?("BEGIN") && first.value.casecmp?("VCARD") &&
        last.name.casecmp?("END") && last.value.casecmp?("VCARD") &&
        properties.any? { it.name.casecmp?("VERSION") }
    end

    # The value of the card's UID property, if it carries one. Names
    # compare without case, as the index's NOCASE collation already
    # assumes for them.
    #: () -> String?
    def uid
      properties.find { it.name.casecmp?("UID") }&.value
    end

    # The lines naming `name`, and the card without them: the split
    # every caller that moves a property makes, so none of them has to
    # rejoin the rest by hand and none can lose a byte doing it. The
    # taken lines come back parsed beside their bytes; what is left
    # comes back a card, ready to store or to take another split.
    #: (String name) -> [Array[Parser::Line], VCard]
    def extract(name)
      taken, rest = lines.partition { it.names?(name) }
      [taken, VCard.new(rest.map(&:verbatim).join)]
    end

    # The card's bytes, exactly as it was given them.
    #: () -> String
    def to_s = @bytes

    # The card's logical lines, each parsed beside its verbatim bytes —
    # the enumeration the questions that move bytes are asked over. A
    # continuation travels with its line, terminators attached, so no
    # line's bytes are lost or normalized on the way through (RFC 2426
    # section 2.6 folding).
    #: () -> Array[Parser::Line]
    def lines
      return @lines if defined?(@lines)

      @lines = Parser.lines(@bytes)
    end

    # The lines naming `name` swapped for the given ones, at the first
    # match's position — the operation a property a card carries one of
    # (N, FN, NICKNAME, NOTE) is edited through, which must not drag
    # the property to the card's end the way #extract plus #insert
    # would. Empty lines remove the property: blank is absent, the
    # reader's own rule (Contact#text_of) in the other direction. A
    # card lacking the property is #insert's case, the lines landing
    # before END:VCARD. Every other line keeps its own bytes, which is
    # the editor's whole safety: a line a save never mentioned cannot
    # be lost by an operation that only touches the lines it names.
    #: (String name, Array[String] lines) -> VCard
    def replace(name, lines)
      all = self.lines
      first = all.index { it.names?(name) }
      return insert(lines) if first.nil?

      # The replaced line's own terminator, so a card written in one
      # line-break convention stays single-convention; a terminated
      # replacement line keeps its own, folds and all.
      terminator = terminator_of(all.fetch(first).verbatim)
      replacements = lines.map { it.end_with?("\n") ? it : it + terminator }
      kept = all.reject { it.names?(name) }.map(&:verbatim)
      # `first` still names the splice point: the lines before it are
      # untouched, and every line it counted past was a named one.
      kept.insert(first, *replacements)
      VCard.new(kept.join)
    end

    # The one-line edit, for a property a card carries many of (TEL,
    # EMAIL, ADR): the line whose verbatim bytes hash to `digest`
    # swaps for the given ones, or is removed when they are empty.
    # Which line a digest names was settled by the caller that watched
    # the card render; a digest matching no line here is that
    # caller's anomaly and raises (KeyError) rather than guessing —
    # the snapshot guard makes a miss news, not an ordinary case. A
    # card carrying the same line twice is addressed as one row by
    # both copies (they hash alike), and this substitutes the first;
    # the digests cannot tell identical bytes apart. A replacement
    # line with no terminator of its own takes the substituted line's,
    # #replace's own convention rule.
    #: (String digest, Array[String] lines) -> VCard
    def substitute(digest, lines)
      all = self.lines
      index = all.index { it.digest == digest }
      raise KeyError, "no line of this card hashes to #{digest}" if index.nil?

      terminator = terminator_of(all.fetch(index).verbatim)
      replacements = lines.map { it.end_with?("\n") ? it : it + terminator }
      kept = all.map(&:verbatim)
      kept.delete_at(index)
      kept.insert(index, *replacements)
      VCard.new(kept.join)
    end

    # Lines into the card immediately before END:VCARD. A line with no
    # terminator of its own takes the END line's, so a card stays
    # single-convention; a terminated line keeps its own, folds and
    # all. With no END to anchor to there is no envelope worth
    # respecting, and the lines are appended with CRLF.
    #
    # A card back, like #extract's remainder: text with text put into it
    # is still text, so there is nothing here for a caller to re-read or
    # re-judge, and one that wants the bytes asks #to_s for them.
    #: (Array[String] lines) -> VCard
    def insert(lines)
      return self if lines.empty?

      physical = physical_lines
      index = physical.rindex { it.match?(END_LINE) }
      if index
        terminator = terminator_of(physical.fetch(index))
        physical.insert(index, *lines.map { it.end_with?("\n") ? it : it + terminator })
        VCard.new(physical.join)
      else
        VCard.new(@bytes + lines.map { it.end_with?("\n") ? it : it + "\r\n" }.join)
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
