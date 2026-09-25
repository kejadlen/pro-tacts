module ProTacts
  # The shape of the one NOTE a served card carries: the member's own
  # text first, then a section per lending group — a blank line, the
  # header `Shared · <label>:`, one newline, the body. Why a group's
  # note rides inside the text value and nowhere else, and why the
  # header is words, is docs/plans/2026-09-25-one-note-per-contact.md.
  #
  # Pure text algebra, the two halves of one round trip: #join is what
  # composition writes, exactly one way, so an untouched card composes
  # back to the bytes it was served with; #split is what a PUT is read
  # with, tolerant of the whitespace a person's editing moves between
  # sections, because headers and not separators are the structure.
  # Neither knows what a group is — attribution is EditedContact's,
  # which knows what the contact's groups lend.
  module NoteSections
    # The fixed half of every header. Rare enough at line start that a
    # collision needs a member's own text to open a line with the
    # phrase plus a lending group's label.
    HEADER = "Shared · ".freeze #: String

    # One labeled part of a combined value: the lending group's label
    # and the text its row holds, shorn of its NOTE line. A Data class,
    # whose members the inline parser cannot read (see
    # sig/pro_tacts/contact.rbs).
    # @rbs skip
    Section = Data.define(:label, :text)

    # What #split read out of a value: the member's own text ("" for
    # none) and the sections in the order they stand. The same shape
    # for a value with nothing lent, whose labels were empty and whose
    # text is all member.
    # @rbs skip
    Split = Data.define(:member, :sections)

    # The value to serve: member text and sections in the order given,
    # blank line between parts. A part with no text is its header
    # alone. Which sections and in what order is the caller's —
    # inheritance order, the order the group's rows lend in.
    #: (String member, Array[Section] sections) -> String
    def self.join(member, sections)
      parts = [] #: Array[String]
      parts << member unless member.empty?
      sections.each do |section|
        parts << (section.text.empty? ? header(section.label) : "#{header(section.label)}\n#{section.text}")
      end
      parts.join("\n\n")
    end

    # The value read back: everything before the first header is the
    # member's own text, each header opens the section of its label,
    # and a section runs to the next header or the end. A header is a
    # line exactly equal to `Shared · <label>:` with trailing
    # whitespace gone, for none of the labels it names — a label
    # nothing lends is a header nowhere, so stale text from an old
    # value reads as member text and not as a mangle. Duplicate labels
    # are the caller's to refuse before this: one header cannot say
    # which of two it names. Leading and trailing blank lines come
    # off both halves — they are the separators the composer writes and
    # whatever a person left behind — and blank lines inside a body
    # stay, a multiline note keeping its own paragraphs. A member text
    # that was all blanks reads as "", which is the caller's no-note.
    #: (String value, Array[String] labels) -> Split
    def self.split(value, labels)
      headers = labels.to_h {
        [header(it), it] #: [String, String]
      }
      member = [] #: Array[String]
      found = [] #: Array[Array[String]]
      value.split("\n", -1).each do |line|
        label = headers[line.rstrip]
        if label.nil?
          if found.empty?
            member << line
          else
            found.fetch(-1) << line
          end
        else
          found << [label]
        end
      end
      Split.new(
        member: trimmed(member),
        sections: found.map { |lines| Section.new(label: lines.fetch(0), text: trimmed(lines.drop(1))) },
      )
    end

    #: (String label) -> String
    def self.header(label)
      "#{HEADER}#{label}:"
    end

    # The lines with their leading and trailing blank lines off —
    # everything a body is, and none of the space around it.
    #: (Array[String] lines) -> String
    def self.trimmed(lines)
      from = lines.index { !it.strip.empty? } || lines.length
      body = lines[from..] || [] #: Array[String]
      upto = body.rindex { !it.strip.empty? } || -1
      body[0..upto].to_a.join("\n")
    end
  end
end
