require "json"

require "pro_tacts/birthday"
require "pro_tacts/import/vcf"
require "pro_tacts/vcard"

module ProTacts
  module Import
    # Monica 4's account export (Settings, Export, "Export to JSON"),
    # read as the .vcf the rest of the import already walks
    # (docs/plans/2026-09-25-importing-from-monica.md).
    #
    # Monica's own vCards leave out most of what Monica is for — notes,
    # relationships, pets — and its JSON export is the one place those
    # come out whole. So this composes a card per contact out of it, and
    # everything after the upload is the walk as it was: the composed
    # file is staged as the import's original, pared by Vcf.read, and
    # read beside the editor a contact at a time.
    #
    # A composed card carries everything, not only what this book
    # reads. What Monica knows and no screen here shows goes in as an
    # X-MONICA- line, struck on the card as exported like any other
    # line not coming in: the left-hand card is the whole record, so
    # nothing is lost without having been shown first. What reads as
    # prose about the person — the notes, the relationships, the pets —
    # is joined into the one NOTE instead, that being the one place in
    # a contact that holds prose.
    #
    # The shapes read here are Monica's own export resources
    # (app/ExportResources on its 4.x branch): each record is its
    # columns, a `properties` object, and a `data` array of collections
    # `{count, type, values}` named by the resource they hold.
    module Monica
      # Monica's relationship type names, as its English interface
      # spells them (resources/lang/en/app.php). A type an account made
      # up itself is its own name, which is already words.
      RELATIONSHIPS = {
        "partner" => "significant other",
        "inlovewith" => "in love with",
        "lovedby" => "loved by",
        "ex" => "ex-partner",
        "stepparent" => "step-parent",
        "godfather" => "godparent",
        "godson" => "godchild",
        "bestfriend" => "best friend",
        "protege" => "protégé",
      }.freeze #: Hash[String, String]

      # Whether an upload is a JSON document rather than a .vcf — asked
      # of the bytes rather than the file's name, which is the
      # browser's to get wrong. A vCard begins with BEGIN.
      #: (String bytes) -> bool
      def self.export?(bytes)
        bytes.lstrip.start_with?("{")
      end

      # The export as a .vcf, a card per contact in the order the export
      # lists them. A contact Monica only knows by name — `is_partial`,
      # the relative added from someone else's page — is not a card of
      # its own; it is a name in the relationships of the contacts it
      # is related to.
      #: (String bytes) -> String
      def self.vcf(bytes)
        account = account_of(bytes)
        contacts = records(account, "contact")
        names = {} #: Hash[String, String]
        contacts.each { names[uuid_of(it)] = name_of(props(it)) }
        photos = {} #: Hash[String, String]
        records(account, "photo").each { photos[uuid_of(it)] = props(it)["dataUrl"].to_s }
        field_types = {} #: Hash[String, Hash[String, untyped]]
        list(account.dig("instance", "contact_field_types")).each { field_types[uuid_of(it)] = props(it) }
        activities = {} #: Hash[String, Hash[String, untyped]]
        records(account, "activity").each { activities[uuid_of(it)] = props(it) }
        relationships = records(account, "relationship").group_by { props(it)["contact_is"].to_s }

        cards = contacts.reject { props(it)["is_partial"] }.map { |contact|
          card(contact, names:, photos:, field_types:, activities:,
                        relationships: relationships.fetch(contact["uuid"].to_s, []))
        }
        raise Vcf::Invalid, "this Monica export holds no contacts" if cards.empty?

        cards.join
      end

      # The export's account, or a refusal naming what the file is not.
      #: (String bytes) -> Hash[String, untyped]
      def self.account_of(bytes)
        parsed = JSON.parse(bytes)
        account = parsed["account"] if parsed.is_a?(Hash)
        return account if account.is_a?(Hash)

        raise Vcf::Invalid, "this is JSON, but not a Monica export"
      rescue JSON::ParserError
        raise Vcf::Invalid, "this file is neither a set of vCards nor JSON"
      end

      # One collection's values out of a record's `data`, and none when
      # the record has none of that kind: Monica leaves an empty
      # collection out rather than writing it empty.
      #: (Hash[String, untyped] record, String type) -> Array[untyped]
      def self.records(record, type)
        collection = list(record["data"]).find { it.is_a?(Hash) && it["type"] == type }
        collection ? list(collection["values"]) : []
      end

      # A value the export says is a list, or none where it is not one.
      #: (untyped value) -> Array[untyped]
      def self.list(value)
        value.is_a?(Array) ? value : []
      end

      # A record's own id, which is how every other record names it.
      #: (untyped record) -> String
      def self.uuid_of(record)
        record.is_a?(Hash) ? record["uuid"].to_s : record.to_s
      end

      #: (untyped record) -> Hash[String, untyped]
      def self.props(record)
        properties = record.is_a?(Hash) ? record["properties"] : nil
        properties.is_a?(Hash) ? properties : {}
      end

      # A person as a note names them: the names Monica shows, in the
      # western order it shows them.
      #: (Hash[String, untyped] properties) -> String
      def self.name_of(properties)
        %w[first_name middle_name last_name].filter_map { properties[it].to_s.strip.then { it unless it.empty? } }.join(" ")
      end

      #: (Hash[String, untyped] contact, names: Hash[String, String], photos: Hash[String, String], field_types: Hash[String, Hash[String, untyped]], activities: Hash[String, Hash[String, untyped]], relationships: Array[untyped]) -> String
      def self.card(contact, names:, photos:, field_types:, activities:, relationships:)
        properties = props(contact)
        lines = ["BEGIN:VCARD", "VERSION:3.0"] #: Array[String?]
        first, middle, last = %w[first_name middle_name last_name].map { VCard.escape(properties[it].to_s.strip) }
        lines << "N:#{last};#{first};#{middle};;"
        lines << "FN:#{VCard.escape(name_of(properties))}"
        lines << text("NICKNAME", properties["nickname"])
        lines << text("ORG", properties["company"])
        lines << text("TITLE", properties["job"])
        lines << birthday(properties["birthdate"])

        records(contact, "contact_field").each do |field|
          lines << contact_field(props(field), field_types[props(field)["type"].to_s] || {})
        end
        records(contact, "address").each_with_index do |address, index|
          lines.concat(address(props(address), index + 1))
        end
        lines << photo(properties.dig("avatar", "avatar_photo"), photos)

        tags = list(properties["tags"]).map { VCard.escape(it.to_s) }
        lines << "CATEGORIES:#{tags.join(",")}" unless tags.empty?

        lines << text("NOTE", note(contact, names:, relationships:))
        lines.concat(left_behind(contact, activities))
        lines << "UID:#{contact["uuid"]}"
        lines << "END:VCARD"
        lines.compact.map { "#{it}\r\n" }.join
      end

      # A text property's line, or none for a blank value.
      #: (String name, untyped value) -> String?
      def self.text(name, value)
        value = value.to_s.strip
        "#{name}:#{VCard.escape(value)}" unless value.empty?
      end

      # A SpecialDate (Monica's own date model) as BDAY, where a card can
      # spell it: a whole date, or a month and day when Monica was told
      # the year is unknown. One Monica worked out from an age holds a
      # year it guessed and a day it made up, which no card can spell
      # truthfully, so it stays behind as a line of its own for the
      # importer to read and enter on the contact's own page.
      #: (untyped date) -> String?
      def self.birthday(date)
        return nil unless date.is_a?(Hash)

        match = date["date"].to_s.match(/\A(\d{4})-(\d{2})-(\d{2})/)
        return nil if match.nil?

        year, month, day = match.captures.map(&:to_i)
        return "X-MONICA-AGE-BASED-BIRTHDAY:about #{year}" if date["is_age_based"]

        Birthday.new(year: date["is_year_unknown"] ? nil : year, month:, day:).to_line
      rescue ArgumentError
        nil
      end

      # A contact field: a phone or an email by the type Monica filed it
      # under, and anything else — Facebook, Twitter, a type the account
      # made up — as a social profile named for that type, which no
      # screen here shows.
      #: (Hash[String, untyped] field, Hash[String, untyped] type) -> String?
      def self.contact_field(field, type)
        value = field["data"].to_s.strip
        return nil if value.empty?

        case type["type"]
        when "phone" then "TEL:#{VCard.escape(value)}"
        when "email" then "EMAIL;type=INTERNET:#{VCard.escape(value)}"
        else "X-SOCIALPROFILE;type=#{type["name"].to_s.gsub(/[^\w-]/, "")}:#{VCard.escape(value)}"
        end
      end

      # An address, labelled with the name Monica gave it (a free-text
      # "Home" or "Summer house") the way Contacts labels a row: a
      # grouped X-ABLabel beside it, which Vcf.read keeps with its line.
      #: (Hash[String, untyped] address, Integer item) -> Array[String]
      def self.address(address, item)
        components = %w[street city province postal_code country].map { VCard.escape(address[it].to_s.strip) }
        return [] if components.all?(&:empty?)

        street, city, province, postal, country = components
        label = address["name"].to_s.strip
        return ["ADR:;;#{street};#{city};#{province};#{postal};#{country}"] if label.empty?

        ["item#{item}.ADR:;;#{street};#{city};#{province};#{postal};#{country}",
         "item#{item}.X-ABLabel:#{VCard.escape(label)}"]
      end

      # The avatar Monica stored, out of the account's photos, where it
      # is a data URL. A Gravatar or a link to someone else's server is
      # not a picture this export holds.
      #: (untyped uuid, Hash[String, String] photos) -> String?
      def self.photo(uuid, photos)
        match = photos.fetch(uuid.to_s, "").match(%r{\Adata:image/(\w+);base64,(.+)\z}m)
        return nil if match.nil?

        type, payload = match.captures
        "PHOTO;ENCODING=b;TYPE=#{type.to_s.upcase}:#{payload.to_s.delete("\r\n")}"
      end

      # The one NOTE: what Monica holds as prose about the person, a
      # paragraph each. The contact's description and its notes first,
      # those being words someone wrote; then the facts Monica keeps as
      # records, spelled out — who they are related to, their pets,
      # what they eat, how you met.
      #: (Hash[String, untyped] contact, names: Hash[String, String], relationships: Array[untyped]) -> String
      def self.note(contact, names:, relationships:)
        properties = props(contact)
        paragraphs = [properties["description"].to_s.strip]
        paragraphs.concat(records(contact, "note").map { props(it)["body"].to_s.strip })

        paragraphs << relationships.filter_map { |relationship|
          related = props(relationship)
          name = names[related["of_contact"].to_s]
          next if name.nil? || name.empty?

          type = related["type"].to_s
          "#{RELATIONSHIPS.fetch(type, type).capitalize}: #{name}"
        }.join("\n")

        paragraphs << records(contact, "pet").filter_map { |pet|
          name, category = props(pet).values_at("name", "category").map { it.to_s.strip }
          next if name.empty? && category.empty?

          next "Pet: #{category}" if name.empty?

          category.empty? ? "Pet: #{name}" : "Pet: #{name} (#{category})"
        }.join("\n")

        food = properties["food_preferences"].to_s.strip
        paragraphs << "Food preferences: #{food}" unless food.empty?

        met = [date_of(properties["first_met_date"]), names[properties["first_met_through"].to_s]]
        paragraphs << "Met #{[met[0], met[1] && "through #{met[1]}"].compact.join(" ")}" if met.any?

        paragraphs.reject(&:empty?).join("\n\n")
      end

      # What Monica keeps about a person that is neither a field here
      # nor prose worth a note: things to do, things that happened,
      # money and gifts. Each a line on the card as exported, struck
      # there with the rest of what is not coming in, so the importer
      # can copy the one worth keeping into the note by hand.
      #: (Hash[String, untyped] contact, Hash[String, Hash[String, untyped]] activities) -> Array[String]
      def self.left_behind(contact, activities)
        properties = props(contact)
        lines = [] #: Array[String?]
        deceased = date_of(properties["deceased_date"])
        lines << "X-MONICA-DECEASED:#{deceased || "yes"}" if properties["is_dead"]

        {
          "reminder" => %w[initial_date title],
          "task" => %w[title description],
          "call" => %w[called_at content],
          "conversation" => %w[happened_at],
          "life_event" => %w[happened_at name note],
          "gift" => %w[name comment],
          "debt" => %w[amount currency],
        }.each do |type, fields|
          records(contact, type).each do |record|
            lines << left_line(type, props(record), fields)
          end
        end
        records(contact, "activity").each do |uuid|
          lines << left_line("activity", activities[uuid.to_s] || {}, %w[happened_at summary])
        end
        lines.compact
      end

      # One left-behind record as a line: its fields that say something,
      # a date read as a date, in the order given.
      #: (String type, Hash[String, untyped] record, Array[String] fields) -> String?
      def self.left_line(type, record, fields)
        values = fields.filter_map { |field|
          value = record[field].to_s.strip
          value = value[0, 10] if value.match?(/\A\d{4}-\d{2}-\d{2}T/)
          value unless value.empty?
        }
        return nil if values.empty?

        "X-MONICA-#{type.upcase.tr("_", "-")}:#{VCard.escape(values.join(" — "))}"
      end

      # A SpecialDate as the day it names, or none. The year stays even
      # where Monica was not told it, the reader here being a person.
      #: (untyped date) -> String?
      def self.date_of(date)
        date.is_a?(Hash) ? date["date"].to_s[0, 10].then { it unless it.empty? } : nil
      end

      private_class_method :account_of, :records, :list, :uuid_of, :props, :name_of, :card, :text, :birthday,
                           :contact_field, :address, :photo, :note, :left_behind, :left_line, :date_of
    end
  end
end
