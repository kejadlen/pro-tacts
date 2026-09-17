require "json"
require "open3"
require "pathname"

require "pro_tacts/change_id"
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

        body = VCard::Parser.lines(vcard).filter_map { line(it, source_id, unknown) }
        # Beyond the vCard: what the serializer leaves out.
        unknown.add("note", source_id, note) if note
        image = contact.fetch("imageData") #: String?
        unknown.add("imageData", source_id, image) if image

        backup = {"original.vcf" => vcard, "contact.json" => JSON.pretty_generate(contact)}
        backup["note.txt"] = note if note

        Plan::Entry.new(
          id:, source_id:,
          card: "BEGIN:VCARD\r\nVERSION:3.0\r\n#{body.join}UID:#{id}\r\nEND:VCARD\r\n",
          backup:
        )
      end

      # A line of the source card as a line of the imported one, or nil for
      # one it does not carry. The envelope is written around the lines
      # rather than carried, so the card's UID can go inside it.
      #: (VCard::Parser::Line line, String source_id, Unknown unknown) -> String?
      def self.line(line, source_id, unknown)
        property = line.property
        example = VCard::Parser.unfold(line.verbatim).chomp
        if property.nil?
          unknown.add("unreadable line", source_id, example) unless example.strip.empty?
          return
        end

        case property.name.upcase
        when "BEGIN", "END"
          nil
        when "VERSION"
          unknown.add("VERSION:#{property.value}", source_id, example) unless property.value == "3.0"
          nil
        else
          unknown.add(property.name.upcase, source_id, example)
          nil
        end
      end

      private_class_method :entry, :line
    end
  end
end
