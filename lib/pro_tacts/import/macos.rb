require "json"
require "open3"
require "pathname"

require "pro_tacts/change_id"
require "pro_tacts/import/card"
require "pro_tacts/import/plan"
require "pro_tacts/vcard/parser"

module ProTacts
  module Import
    # A plan from this Mac's iCloud contacts, read by
    # script/macos-contacts.swift. The builder knows only the fields it has
    # been taught, and refuses the rest
    # (docs/plans/2026-09-16-importing-from-macos.md, "The builder knows
    # only what it was taught").
    module Macos
      SCRIPT = Pathname.new(__FILE__).dirname.join("../../../script/macos-contacts.swift").expand_path #: Pathname

      # Every field no branch handles, across every contact read, so one
      # build names all of them.
      class Unknown < StandardError
        # @rbs @seen: Hash[String, Array[[String, String]]]

        EXAMPLES = 3 #: Integer

        # Long enough for a line's parameters, short of a photo's payload.
        EXAMPLE_LENGTH = 100 #: Integer

        #: () -> void
        def initialize
          @seen = Hash.new { |seen, field| seen[field] = [] }
          super
        end

        #: (String field, String source_id, String example) -> void
        def add(field, source_id, example)
          @seen[field] << [source_id, example]
        end

        #: () -> bool
        def any? = !@seen.empty?

        #: () -> String
        def message
          lines = @seen.sort.flat_map do |field, seen|
            examples = seen.uniq(&:last).first(EXAMPLES).map do |source_id, example|
              "    #{source_id}: #{truncate(example).inspect}"
            end
            ["  #{field}: #{seen.size}", *examples]
          end
          "no branch handles these fields, so no plan was written:\n#{lines.join("\n")}"
        end

        private

        #: (String example) -> String
        def truncate(example)
          return example if example.length <= EXAMPLE_LENGTH

          "#{example[0, EXAMPLE_LENGTH]}… (#{example.length} characters)"
        end
      end

      # The reader's output, one parsed object per contact.
      #: (limit: Integer?) -> Array[Hash[String, untyped]]
      def self.read(limit:)
        command = ["swift", SCRIPT.to_s, "read"]
        command << limit.to_s if limit
        output, status = Open3.capture2(*command)
        raise "#{SCRIPT.basename} exited #{status.exitstatus}" unless status.success?

        output.each_line.map { JSON.parse(it) }
      end

      #: (Pathname dir, Array[Hash[String, untyped]] records, created_at: Time) -> Plan
      def self.plan(dir, records, created_at:)
        unknown = Unknown.new
        entries = records.map { entry(it, unknown) }
        raise unknown if unknown.any?

        Plan.write(dir, source: "macos", created_at:, entries:)
      end

      #: (Hash[String, untyped] record, Unknown unknown) -> Plan::Entry
      def self.entry(record, unknown)
        id = ChangeId.mint(12)
        source_id = record.fetch("identifier") #: String
        vcard = record.fetch("vcard") #: String
        note = record.fetch("note") #: String?
        contact = record.fetch("contact") #: Hash[String, untyped]

        carried = VCard::Parser.lines(vcard).select { carried?(it, source_id, unknown) }
        first, last = name(carried, source_id, unknown)
        phones = carried.filter_map { it.property&.then { |property| property.text if property.name.casecmp?("TEL") } }
        # Beyond the vCard: what the serializer leaves out.
        unknown.add("note", source_id, note) if note
        image = contact.fetch("imageData") #: String?
        unknown.add("imageData", source_id, image) if image

        backup = {"original.vcf" => vcard, "contact.json" => JSON.pretty_generate(contact)}
        backup["note.txt"] = note if note

        Plan::Entry.new(id:, source_id:, card: Card.new(first:, last:, phones:, groups: []), backup:)
      end

      # Whether a line of the source card is carried into the card's
      # fields; one that is not is recorded unknown or, for the envelope
      # and PRODID, dropped.
      #: (VCard::Parser::Line line, String source_id, Unknown unknown) -> bool
      def self.carried?(line, source_id, unknown)
        property = line.property
        example = example(line)
        if property.nil?
          unknown.add("unreadable line", source_id, example) unless example.strip.empty?
          return false
        end

        name = property.name.upcase
        case name
        when "BEGIN", "END"
          false
        when "VERSION"
          unknown.add("VERSION:#{property.value}", source_id, example) unless property.value == "3.0"
          false
        when "PRODID"
          # Contacts writes its own on every save; the source's stays in the backup.
          form = form(property, example)
          unknown.add(form, source_id, example) unless form == "PRODID"
          unknown.add("PRODID value", source_id, example) unless property.value.start_with?("-//Apple Inc.//")
          false
        when "FN", "N", "TEL"
          refused = [] #: Array[String]
          form = form(property, example)
          refused << form unless FORMS.fetch(name).include?(form)
          refused << "TEL value" if name == "TEL" && !property.value.match?(PHONE)
          refused.each { unknown.add(it, source_id, example) }
          refused.empty?
        else
          unknown.add(name, source_id, example)
          false
        end
      end

      # The first and last name, from the one N, when the one FN is those
      # two joined as the web editor joins them: a card holding more of a
      # name than that would lose it.
      #: (Array[VCard::Parser::Line] lines, String source_id, Unknown unknown) -> [String, String]
      def self.name(lines, source_id, unknown)
        ns = lines.select { it.names?("N") }
        fns = lines.select { it.names?("FN") }
        unknown.add("N lines: #{ns.size}", source_id, ns.map { example(it) }.join(" / ")) unless ns.size == 1
        unknown.add("FN lines: #{fns.size}", source_id, fns.map { example(it) }.join(" / ")) unless fns.size == 1

        n = ns.first
        family, given, *rest = n&.property&.components || []
        first = given.to_s
        last = family.to_s
        unknown.add("N beyond first and last", source_id, example(n)) if n && rest.any? { !it.empty? }
        unknown.add("no name", source_id, n ? example(n) : "") if n && first.empty? && last.empty?

        fn = fns.first
        if fn && fn.property&.text != [first, last].reject(&:empty?).join(" ")
          unknown.add("FN other than first and last", source_id, example(fn))
        end

        [first, last]
      end

      # The spellings each carried property is taken in, group and
      # parameters included, exactly as the source wrote them.
      FORMS = {
        "FN" => ["FN"],
        "N" => ["N"],
        "TEL" => ["TEL;type=CELL;type=VOICE;type=pref"]
      }.freeze #: Hash[String, Array[String]]

      PHONE = /\A\+[0-9]+\z/ #: Regexp

      # A line unfolded, without its terminator.
      #: (VCard::Parser::Line line) -> String
      def self.example(line)
        VCard::Parser.unfold(line.verbatim).chomp
      end

      # A line as the source spelled it, less its value.
      #: (VCard::Parser::Property property, String example) -> String
      def self.form(property, example)
        example.delete_suffix(":#{property.value}")
      end

      private_class_method :entry, :carried?, :name, :example, :form
    end
  end
end
