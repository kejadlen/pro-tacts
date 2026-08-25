
module ProTacts
  # vCard 3.0 (RFC 2426): the line-level rules a card obeys, and the
  # shape a parsed one takes. VCard::Parser reads a card into those;
  # escape and fold write one back out.
  module VCard
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

    # A bare CR is not a line break in the grammar, but it ends a value
    # and has to end a line here too: without it the parser's scanner
    # would sit on one forever, because no token can consume it.
    LINE_BREAK = /\r\n|[\r\n]/ #: Regexp

    # Reads like an alternation-precedence bug and is not: Ruby wraps an
    # interpolated Regexp in a non-capturing group, so this is
    # `(?:\r\n|[\r\n])[ \t]` rather than `\r\n` or `[\r\n][ \t]`.
    FOLD = /#{LINE_BREAK}[ \t]/ #: Regexp

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

    # Text values escape backslash, the component separator, and the
    # sub-component separator (RFC 2426 section 2.4.2); CRLF and CR are
    # normalized to the `\n` escape because a raw line break would end
    # the property line.
    #: (String text) -> String
    def self.escape(text)
      text.gsub(/\r\n|\r/, "\n").gsub(/[\\;,\n]/) { TEXT_ESCAPES.fetch(it) }
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

    # Fold's inverse, and the first thing a parse does: RFC 2426 section
    # 2.6 has a content line unfolded before it is read. It runs over the
    # whole card rather than token by token because a fold can land
    # anywhere in a line — Contacts folds at 75 octets without regard for
    # what it splits — so there is no boundary to do it at.
    #: (String card) -> String
    def self.unfold(card)
      card.gsub(FOLD, "")
    end
  end
end
