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
        run("read", *[limit&.to_s].compact)
      end

      # This Mac as `Remove` speaks to it: the contacts it still has, by
      # source id, and the delete that takes them off it.
      module Mac
        #: (Array[String] source_ids) -> Hash[String, untyped]
        def self.show(source_ids)
          return {} if source_ids.empty?

          Macos.run("show", *source_ids).to_h {
            [it.fetch("identifier"), it] #: [String, untyped]
          }
        end

        # The contacts this Mac would not delete, each to what it said;
        # empty when every one of them left.
        #: (Array[String] source_ids) -> Hash[String, String]
        def self.delete(source_ids)
          return {} if source_ids.empty?

          Macos.run("delete", *source_ids).reject { it.fetch("deleted") }.to_h {
            [it.fetch("identifier"), it.fetch("error")] #: [String, String]
          }
        end
      end

      #: (*String arguments) -> Array[Hash[String, untyped]]
      def self.run(*arguments)
        output, status = Open3.capture2("swift", SCRIPT.to_s, *arguments)
        raise "#{SCRIPT.basename} #{arguments.first} exited #{status.exitstatus}" unless status.success?

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

        lines = VCard::Parser.lines(vcard)
        grouped = grouped(lines)
        carried = lines.select { carried?(it, grouped, source_id, unknown) }
        first, last = name(carried, source_id, unknown)
        nickname = only(carried, "NICKNAME", source_id, unknown)
        birthday = only(carried, "BDAY", source_id, unknown)
        # A number the card left empty is a row Contacts kept the label
        # of and nothing else, and an empty add row inserts nothing
        # (Admin::CardForm).
        phones = values(carried, "TEL").reject(&:empty?)
        emails = values(carried, "EMAIL")
        addresses = properties(carried, "ADR").map { address(it) }
        source = {"identifier" => source_id, "vcard" => vcard, "note" => note, "contact" => contact}
        # Beyond the vCard, and carried from the source the card holds:
        # the note AppleScript gave up, and the picture the serializer
        # leaves out.
        photo = !contact.fetch("imageData").nil?
        card = Card.new(
          first:, last:, nickname:, birthday:, phones:, emails:, addresses:,
          note: noted(note, related_names(lines, carried)), photo:, groups: [], source:
        )
        Plan::Entry.new(id:, source_id:, card:)
      end

      # The note, with the people this contact is related to written
      # under it: this address book has no field for a relation, and a
      # spouse's name is worth more in the note than nowhere.
      #: (String? note, Array[String] related) -> String?
      def self.noted(note, related)
        return note if related.empty?

        [note, related.join("\n")].compact.reject(&:empty?).join("\n\n")
      end

      # Each related name as "<label>: <name>", the label being the
      # X-ABLabel sharing its group — Apple's own labels arrive wrapped
      # (`_$!<Spouse>!$_`) and a person's own arrives as they typed it.
      # The labels are read off every line rather than the carried ones,
      # a label being dropped with the group it annotates.
      #: (Array[VCard::Parser::Line] lines, Array[VCard::Parser::Line] carried) -> Array[String]
      def self.related_names(lines, carried)
        labels = properties(lines, "X-ABLabel").to_h {
          [it.group, VCard.unescape(it.value).sub(/\A_\$!<(.*)>!\$_\z/, "\\1")] #: [String?, String]
        }
        properties(carried, "X-ABRELATEDNAMES").map {
          label = labels[it.group]
          label ? "#{label}: #{it.text}" : it.text
        }
      end

      # The properties of the carried lines naming one property, in the
      # order the card wrote them.
      #: (Array[VCard::Parser::Line] lines, String name) -> Array[VCard::Parser::Property]
      def self.properties(lines, name)
        lines.filter_map { it.property }.select { it.name.casecmp?(name) }
      end

      #: (Array[VCard::Parser::Line] lines, String name) -> Array[String]
      def self.values(lines, name) = properties(lines, name).map(&:text)

      # An address as the editor's add row holds one, the blank
      # components left out rather than written as empty fields.
      #: (VCard::Parser::Property property) -> Hash[String, String]
      def self.address(property)
        # The post office box leads the value and has no field; a card
        # carrying one does not get this far (see ADR's value check).
        _po_box, *parts = property.components
        Card::ADDRESS_KEYS.zip(parts).to_h { |key, value|
          [key, value.to_s] #: [String, String]
        }.reject { |_key, value| value.empty? }
      end

      # The one line naming a property a card holds once, or nil for a
      # card with none; more than one is refused, the field having room
      # for a single value.
      #: (Array[VCard::Parser::Line] lines, String name, String source_id, Unknown unknown) -> String?
      def self.only(lines, name, source_id, unknown)
        found = lines.select { it.names?(name) }
        return found.first&.property&.text if found.size <= 1

        unknown.add("#{name} lines: #{found.size}", source_id, found.map { example(it) }.join(" / "))
        nil
      end

      # The `item` groups this card explains: a group with a line in it
      # that says what the group is for, rather than annotating it.
      #: (Array[VCard::Parser::Line] lines) -> Array[String]
      def self.grouped(lines)
        lines.filter_map { it.property }
          .reject { ANNOTATIONS.include?(it.name.upcase) }
          .filter_map { it.group }
      end

      # Whether a line of the source card is carried into the card's
      # fields; one that is not is recorded unknown or, for the envelope
      # and the dropped properties, left behind.
      #: (VCard::Parser::Line line, Array[String] grouped, String source_id, Unknown unknown) -> bool
      def self.carried?(line, grouped, source_id, unknown)
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
        when *DROPPED
          # Fields this address book does not have. The source keeps
          # them, the card carrying what it was read from.
          false
        when *ANNOTATIONS
          # A line that annotates the line sharing its group — a label,
          # or an address's country code — goes wherever that line goes,
          # which is why dropping `item1.URL` drops `item1.X-ABADR` with
          # it. One annotating nothing is a line with no explanation, so
          # it is unknown like any other.
          group = property.group
          unknown.add(name, source_id, example) unless group && grouped.include?(group)
          false
        when "PRODID"
          # Contacts writes its own on every save; the source's stays in the backup.
          form = form(property, example)
          unknown.add(form, source_id, example) unless form == "PRODID"
          unknown.add("PRODID value", source_id, example) unless property.value.start_with?("-//Apple Inc.//")
          false
        when *FORMS.keys
          refused = [] #: Array[String]
          form = form(property, example)
          refused << form unless FORMS.fetch(name).include?(form)
          refused << "#{name} value" unless value?(name, property)
          refused.each { unknown.add(it, source_id, example) }
          refused.empty? && !dropped_value?(name, property)
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
      # parameters included, as the source wrote them: `item1.` and
      # `item2.` are one spelling, since the number counts a card's
      # groups rather than saying anything about the line, and a
      # trailing `type=pref` is left off, ranking a line rather than
      # naming a kind (Contact#types_of drops it for the same reason).
      FORMS = {
        "FN" => ["FN"],
        "N" => ["N"],
        "NICKNAME" => ["NICKNAME"],
        "BDAY" => ["BDAY"],
        "TEL" => [
          "TEL",
          "TEL;type=CELL;type=VOICE",
          "TEL;type=HOME;type=VOICE",
          "TEL;type=IPHONE;type=CELL;type=VOICE",
          "TEL;type=WORK;type=VOICE",
          "item#.TEL"
        ],
        "EMAIL" => [
          "EMAIL;type=INTERNET",
          "EMAIL;type=INTERNET;type=HOME",
          "EMAIL;type=INTERNET;type=WORK",
          "item#.EMAIL;type=INTERNET"
        ],
        "ADR" => ["ADR;type=HOME", "item#.ADR;type=HOME"],
        "X-ABRELATEDNAMES" => ["item#.X-ABRELATEDNAMES"]
      }.freeze #: Hash[String, Array[String]]

      # A number as Contacts hands one over, which is as a person typed
      # it: "+12532189075" and "(206) 651-4359" are both numbers, and an
      # empty value is a row with no number in it at all.
      PHONE = /\A[0-9 +().-]*\z/ #: Regexp

      # A number with the extension a person wrote after it, "+1 (425)
      # 707-1712 X71712" as one line. Digits have to come first: a value
      # that is an extension and nothing else ("ext. 4") labels a row
      # rather than filling it, and stays refused.
      EXTENSION = /\A[0-9 +().-]*[0-9][0-9 +().-]*(?:x|ext)\.?\s*[0-9]+\z/i #: Regexp

      # Properties read and thrown away, whatever form they take: this
      # address book has no field for any of them, and a card's `source`
      # still holds the line.
      DROPPED = %w[IMPP ORG TITLE URL X-SOCIALPROFILE X-APPLE-SUBADMINISTRATIVEAREA X-AIM].freeze #: Array[String]

      # Properties that say something about the line sharing their group
      # rather than about the contact: a label, and the country code
      # Contacts writes beside an address.
      ANNOTATIONS = %w[X-ABLABEL X-ABADR].freeze #: Array[String]

      # Whether a value is one its field can hold: a phone is a `+` and
      # digits, with or without an extension, a birthday a whole date,
      # an address the seven components RFC 2426 section 3.2.1 gives it
      # with no post office box, since no field carries one. A name is
      # any text, and an email is asked nothing here — see
      # #dropped_value?.
      #: (String name, VCard::Parser::Property property) -> bool
      def self.value?(name, property)
        case name
        when "TEL" then property.value.match?(PHONE) || property.value.match?(EXTENSION)
        when "BDAY" then property.value.match?(Card::BIRTHDAY)
        when "ADR" then property.components.size == 7 && property.components.fetch(0).empty?
        else true
        end
      end

      # A value its field has no use for, dropped rather than refused.
      # An EMAIL without an `@` is not an address at all — Exchange
      # writes a directory name into one
      # (`/O=microsoft/OU=.../cn=algersha`) — so it is not a spelling to
      # learn but a row this address book has no field for, and it goes
      # the way the DROPPED properties go, the source keeping the line.
      # The form is still checked around this, so a value like it in a
      # spelling nobody has seen is reported like any other.
      #: (String name, VCard::Parser::Property property) -> bool
      def self.dropped_value?(name, property)
        name == "EMAIL" && !property.value.include?("@")
      end

      # A line unfolded, without its terminator.
      #: (VCard::Parser::Line line) -> String
      def self.example(line)
        VCard::Parser.unfold(line.verbatim).chomp
      end

      # A line as the source spelled it, less its value.
      #: (VCard::Parser::Property property, String example) -> String
      def self.form(property, example)
        example.delete_suffix(":#{property.value}").sub(/\Aitem\d+\./, "item#.").delete_suffix(";type=pref")
      end

      private_class_method :entry, :grouped, :carried?, :name, :noted, :related_names, :only, :properties, :values, :address, :value?, :dropped_value?, :example, :form
    end
  end
end
