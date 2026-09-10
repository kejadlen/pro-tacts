require "json"

require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  # What one write did to a card, as the lines it added and the lines
  # it removed — the change log's second fact that nothing can
  # recompute (see Store), since the card this one replaced is gone the
  # moment the write lands.
  #
  # A multiset difference over the card's lines, not an edit script:
  # macOS Contacts reorders properties on every card it touches
  # (docs/macos-contacts.md), so a positional diff would report a
  # shuffle as a change to every line below the first move. Lines that
  # both cards carry cancel, however far apart they sit, and what is
  # left is the write. A card carrying the same line twice is two
  # lines, which is why this counts rather than sets: dropping one copy
  # is a removal, and a set difference would call it nothing.
  #
  # The unit is the logical line unfolded and shorn of its terminator,
  # which is the line as the grammar reads it (RFC 2426 section 2.6
  # folding). So a fold moved or a card rewritten CRLF for LF is no
  # change here, and the diff is a record of a card's lines rather than
  # of its bytes — it cannot rebuild the card it came from, and is not
  # meant to.
  #
  # The signature lives in sig/pro_tacts/card_diff.rbs, this being a
  # Data class.
  # @rbs skip
  CardDiff = Data.define(:added, :removed)

  # Reopened rather than defined in the block above, for the reason
  # VCard::Parser::Property is.
  class CardDiff
    # The write from the card before it to the card after it, either of
    # them nil: a create adds every line of a card that was not there,
    # and a delete removes every line of one that will not be.
    #: (VCard? before, VCard? after) -> CardDiff
    def self.between(before, after)
      old_lines = content_lines(before)
      new_lines = content_lines(after)
      new(added: without(new_lines, old_lines), removed: without(old_lines, new_lines))
    end

    # The stored spelling: a JSON object, so a line goes in and comes
    # back byte for byte whatever it holds. A diff is displayed beside
    # the entry it belongs to and never queried, so the column is one
    # value rather than a table of lines.
    #: (String json) -> CardDiff
    def self.from_json(json)
      parsed = JSON.parse(json) #: Hash[String, Array[String]]
      new(added: parsed.fetch("added"), removed: parsed.fetch("removed"))
    end

    # A card's lines, each unfolded and stripped of its terminator. The
    # blank line a card may end with reads as no line at all, the same
    # answer Parser gives it, so a card's trailing whitespace is not a
    # line to add or remove.
    #: (VCard? vcard) -> Array[String]
    def self.content_lines(vcard)
      return [] if vcard.nil?

      vcard.lines.filter_map {
        line = VCard::Parser.unfold(it.verbatim).sub(/(\r\n|[\r\n])\z/, "")
        line unless line.empty?
      }
    end

    # `lines` minus one occurrence of each line `others` also carries.
    # Order is the card's own, so a diff reads down the card the lines
    # came from.
    #: (Array[String] lines, Array[String] others) -> Array[String]
    def self.without(lines, others)
      remaining = others.tally
      lines.reject { |line|
        count = remaining.fetch(line, 0)
        next false if count.zero?

        remaining[line] = count - 1
        true
      }
    end

    private_class_method :content_lines, :without

    #: () -> bool
    def empty? = added.empty? && removed.empty?

    #: () -> String
    def to_json(*) = {added:, removed:}.to_json
  end
end
