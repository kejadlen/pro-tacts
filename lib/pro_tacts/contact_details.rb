require "base64"
require "digest"
require "sentry-ruby"

require "pro_tacts/birthday"
require "pro_tacts/note_sections"
require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  # The readings over card bytes — the readers a card answers about
  # itself no matter who holds it: name, nickname, sort, organization,
  # the phones, emails, and handles a card carries as lines
  # (docs/plans/2026-10-25-contacts-on-entities.md, "The types").
  # Included by ContactDetails and ListedContact, which replaces the
  # one-by-one forwarding; the addresses and the note are components
  # and read from the holders, not from here.
  #
  # The readings walk the *stored* card — the host's `stored` — which
  # composes nothing. The served card adds only ADR, NOTE, and BDAY
  # lines (#ContactDetails#vcard), so every reading here answers the
  # same over either card, and the listing paths that read nothing but
  # these never pay for a composition.
  module ContactReadings
    # The card the readings walk, the host's own.
    #: () -> VCard
    def stored
      raise NotImplementedError, "a host of ContactReadings holds the stored card"
    end
    # FN's value (RFC 2426 section 3.1.1), in text form.
    #: () -> String?
    def name
      text_of(stored.property("FN"))
    end

    # N's components (RFC 2426 section 3.1.2: family; given; additional;
    # prefixes; suffixes), split and unescaped, or nil with no N at all.
    # Structured data — reading initials off it is the real answer to
    # where a first/last split falls, rather than guessing in the
    # free-text FN.
    #: () -> Array[String?]?
    def name_components
      property = stored.property("N")
      property && components_of(property)
    end

    # NICKNAME's value (RFC 2426 section 3.1.3), in text form — the
    # whole value, as the card spells it, when it comma-lists several.
    #: () -> String?
    def nickname
      text_of(stored.property("NICKNAME"))
    end

    # The order a contact lists under: N's family name (RFC 2426
    # section 3.1.2), falling back to FN, case-insensitive so the
    # card's spelling of a family name does not move it. What a card
    # with no name at all sorts under is the holder's fact — Contact
    # falls back to its id — so the classes that carry one override.
    #: () -> String
    def sort_key
      family, = name_components || []
      (family || name).to_s.downcase
    end

    # ORG's value (RFC 2426 section 3.5.5), in text form — the whole
    # value as the card spells it, org name and units together, which
    # is what a search reads; no screen has asked for the components
    # apart yet.
    #: () -> String?
    def organization
      text_of(stored.property("ORG"))
    end

    # Whether the card shows as a company rather than a person:
    # Apple's X-ABShowAs:COMPANY, the spelling Contacts.app writes and
    # reads — the phone labels' own precedent for trusting an X-
    # property (docs/plans/2026-09-18-phone-labels.md). Display's fact
    # alone, and a different property from #organization's: a person
    # carries ORG without the flag, and neither is bound to the other.
    #: () -> bool
    def company?
      stored.property("X-ABShowAs")&.text == "COMPANY"
    end

    #: () -> Array[ContactDetails::Phone]
    def phones
      labels = label_lines
      rows("TEL") { |property, line|
        value = text_of(property)
        # RFC 2426 section 3.3.1: `voice` is the type every number has
        # by default, so it names none.
        ContactDetails::Phone.new(
          value:,
          label_line: label_line_of(property, labels),
          types: property.types - %w[voice],
          line:,
          property:,
        ) if value
      }
    end

    #: () -> Array[ContactDetails::Email]
    def emails
      labels = label_lines
      rows("EMAIL") { |property, line|
        value = text_of(property)
        # RFC 2426 section 3.3.2: `internet` is the format every address
        # has by default, so it names none.
        ContactDetails::Email.new(
          value:,
          label_line: label_line_of(property, labels),
          types: property.types - %w[internet],
          line:,
          property:,
        ) if value
      }
    end

    # A line whose value carries no scheme is no URI and no handle
    # this reader can split, and reads as none — the property stays
    # the card's own, shown by ContactDetails#properties.
    #: () -> Array[ContactDetails::Handle]
    def handles
      rows("IMPP") { |property, line|
        scheme, handle = text_of(property)&.split(":", 2)
        next if scheme.nil? || handle.nil? || handle.empty?

        ContactDetails::Handle.new(
          service: property.parameter("X-SERVICE-TYPE"), value: handle, scheme:, line:, property:
        )
      }
    end

    private

    # A property group to the `X-ABLabel` line anchoring it — the
    # label a line's group carries, on a different line than the row it
    # describes. Read off the stored card's own lines: a phone's label
    # names a line the card brought, and the addresses a contact
    # composes render under `item` groups of their own
    # (ContactDetails.address_lines), so the two never share one. Keyed
    # lowercased, a group name comparing without case as a property
    # name does and as EditedContact#label_of pairs them. A label with
    # no text labels nothing, and is left out.
    #: () -> Hash[String, VCard::Parser::Line]
    def label_lines
      stored.lines
        .filter_map { |line|
          property = line.property
          next if property.nil? || !property.name.casecmp?("X-ABLabel")

          group = property.group
          next if group.nil? || text_of(property).nil?

          [group.downcase, line] #: [String, VCard::Parser::Line]
        }
        .to_h
    end

    #: (VCard::Parser::Property property, Hash[String, VCard::Parser::Line] labels) -> VCard::Parser::Line?
    def label_line_of(property, labels)
      group = property.group
      labels[group.downcase] if group
    end

    # The rows a repeatable property reads as: each line naming it
    # folded by the block, which answers nil for a row with nothing
    # to show.
    #: [T] (String name) { (VCard::Parser::Property, VCard::Parser::Line) -> T? } -> Array[T]
    def rows(name)
      stored.lines.filter_map { |line|
        next unless line.names?(name)

        property = line.property
        yield(property, line) unless property.nil?
      }
    end

    # A text property's value, with the empty one reading as absent:
    # a property whose value carries nothing is one no caller has to
    # tell apart from a property that is not there.
    #: (VCard::Parser::Property? property) -> String?
    def text_of(property)
      return if property.nil?

      value = property.text
      value.empty? ? nil : value
    end

    # A structured value's components, nil in the positions the card
    # left blank: an empty component is as absent as one past the end
    # of the value, and reads the same.
    #: (VCard::Parser::Property property) -> Array[String?]
    def components_of(property)
      property.components.map { it.empty? ? nil : it }
    end
  end

  # What a card says, with or without an entity behind it: the stored
  # card, the birthday, and the addresses and note its entity holds,
  # from which #vcard composes the card a client downloads — the one
  # model of a contact's details
  # (docs/plans/2026-09-01-contact-is-the-model.md, generalized by
  # docs/plans/2026-10-25-contacts-on-entities.md, "The types").
  #
  # An entity-less details is a card on its way somewhere rather than
  # a record in the book: an import's preview, a submission being read
  # back (EditedContact), the index's reading of a card (ListedContact
  # holds one behind its own readings). The caller hands over the
  # addresses and the note, because components are keyed by an entity
  # a details does not have. A Contact is this class with the entity's
  # id — the subclass keeps an entity-less card out of the screens
  # that link by one — and only the store makes one of those.
  #
  # What it holds is the *stored* card — a VCard rather than its bytes,
  # since every caller handing one over already had a card in hand and
  # a class holding bytes would have to make one to answer anything —
  # with the birthday and the components beside it rather than parsed
  # back out of the card they compose into. Why each sits beside the
  # card instead of in it, and why they are independent rather than two
  # spellings of one fact, is
  # docs/plans/2026-09-05-contact-takes-its-structure.md,
  # docs/plans/2026-08-31-partial-birthdays.md, and that plan. An
  # unmodeled BDAY spelling stays the card's own: #properties shows it,
  # and #birthday reads nil over it.
  #
  # The etag hashes the composed card, so it changes exactly when what
  # the client downloads changes, and is derived here and stored
  # nowhere — one constructor, rather than one that computes it and one
  # that takes it on trust. Quoted, the entity-tag's own form (RFC 7232
  # section 2.3), which both the ETag header and getetag carry.
  #
  # The accessors are deliberately shallow, like the parser: a card can
  # carry properties no accessor knows, and CardDAV still serves every
  # one — #properties is the read for those. Their walk is lazy and
  # that is load-bearing rather than style, for the reason the first
  # plan gives under "Contact stops being a Data class": the paths that
  # answer in bytes never ask.
  class ContactDetails
    # @rbs @stored: VCard
    # @rbs @birthday: Birthday?
    # @rbs @addresses: Array[Address]
    # @rbs @note: String?
    # @rbs @lent: Array[Lent]
    # @rbs @vcard: VCard
    # @rbs @etag: String
    # @rbs @own: ContactDetails

    include ContactReadings

    # The structured shapes the accessors return: text value and types
    # for TEL (RFC 2426 section 3.3.1) and EMAIL (section 3.3.2). A
    # row's `label_line` is the `X-ABLabel` sharing its property
    # group, a different fact from its types
    # (docs/plans/2026-09-18-phone-labels.md, "Reading"), carried as
    # the line so that a save removing the row removes its label with
    # it (docs/plans/2026-10-22-a-row-edits-its-label.md), every
    # shape's `line` the parsed line it was read from, the row a save
    # names by its digest, and `property` that line's reading, which
    # #rows only builds a row from, so a save splicing it never meets a
    # line that would not read.
    # Data classes, whose members the inline syntax cannot read; the
    # signatures live in sig/pro_tacts/contact_details.rbs.
    # @rbs skip
    Phone = Data.define(:value, :label_line, :types, :line, :property)
    # @rbs skip
    Email = Data.define(:value, :label_line, :types, :line, :property)
    # A handle: an IMPP (RFC 6350 section 6.4.3, from RFC 4770 for
    # 3.0) as Contacts.app spells one, the service its X-SERVICE-TYPE
    # parameter and the value the handle, with the URI scheme it sits
    # under kept apart so a save can write it back — Apple's own
    # `x-apple:` for a service with no scheme, Signal's case
    # (docs/plans/2026-10-18-signal-handles.md).
    # @rbs skip
    Handle = Data.define(:service, :value, :scheme, :line, :property)
    # @rbs skip
    Photo = Data.define(:mime_type, :bytes)

    # An address the entity holds: ADR's seven components (RFC 2426
    # section 3.2.1 — a component the entity left blank is "", which
    # reads as absent) and its label, the one word a reader shows
    # (#label_of's reading — an X-ABLabel's text, or the types joined),
    # nil where the address carries none. The component is the record:
    # #address_lines renders it into a card and #take_addresses reads
    # one back, so what moves between cards and components is the
    # reading, never the bytes. `lent_by` is the group lending the row
    # on a served contact, nil on the entity's own — provenance the
    # screens mark a row with, not a fact of the address.
    # @rbs skip
    Address = Data.define(
      :po_box,
      :extended,
      :street,
      :locality,
      :region,
      :postal_code,
      :country,
      :label,
      :lent_by,
    )

    # Reopened rather than defined in the block above, for the reason
    # VCard::Parser::Property is: the default lives here where Steep
    # reads the signature.
    class Address
      #: (?label: String?, ?lent_by: Group?, **untyped) -> void
      def initialize(label: nil, lent_by: nil, **)
        super
      end

      #: () -> Array[String]
      def self.label_words = ContactDetails.typed_words("ADR")

      # The row's fields by form name: each component as the editor
      # shows it, the po box excepted, no field editing it.
      #: () -> Hash[String, String]
      def fields
        ADDRESS_COMPONENTS.to_h { |name|
          pair = [name, public_send(name)] #: [String, String]
          pair
        }
      end
    end

    # What one group lends a contact: its addresses at their positions
    # and its note, whole — the group's components read beside the
    # membership that carries them (Store#lent_of). A group with
    # nothing to lend does not appear.
    # @rbs skip
    Lent = Data.define(:group, :addresses, :note)
    # @rbs skip
    LentAddress = Data.define(:position, :address)

    # An ADR's editable components, in the order the value spells them
    # (RFC 2426 section 3.2.1). The post office box heads that value
    # and is not among them — no screen shows one, and a save preserves
    # its bytes rather than letting a form field near them —
    # so a component's position in the value is one past its index
    # here.
    ADDRESS_COMPONENTS = %w[extended street locality region postal_code country].freeze #: Array[String]

    # The word a row's type column says: the `X-ABLabel` sharing its
    # group, unwrapped from Apple's own vocabulary (`_$!<Other>!$_`
    # reads `Other`), else the types the reader shows, else nil. One
    # word to a reader, whichever of the two spellings the line carries
    # (docs/plans/2026-10-22-a-row-edits-its-label.md, "One word, three
    # spellings"); where a row has both the label wins, which is what
    # Contacts itself shows (docs/plans/2026-09-18-phone-labels.md,
    # "Reading").
    #: (VCard::Parser::Line? label_line, Array[String] types) -> String?
    def self.label_of(label_line, types)
      text = label_line&.property&.text
      return VCard.unwrap(text) unless text.nil? || text.empty?

      types.join(", ") unless types.empty?
    end

    # The words Contacts models as a TYPE value, by the property they
    # type, each to its spelling there: what a client has been seen
    # writing (docs/apple-contacts.md, "The client rewrites every card
    # it touches", and the fixtures), uppercase as Contacts writes
    # them. Any other word is a custom label, the safe direction to be
    # wrong in (docs/plans/2026-10-22-a-row-edits-its-label.md, "The
    # typed kinds' rule"). A word joins when a recorded session shows
    # Contacts spelling it as a type.
    TYPE_WORDS = {
      "TEL" => {"cell" => "CELL", "home" => "HOME", "work" => "WORK"},
      "EMAIL" => {"home" => "HOME", "work" => "WORK"},
      "ADR" => {"home" => "HOME", "work" => "WORK"},
    }.freeze #: Hash[String, Hash[String, String]]

    # Apple's own word for a row of no particular kind, written in its
    # wrapped spelling because that is how the 31 emails labeled Other
    # in the macOS data carry it (docs/plans/2026-09-18-phone-labels.md,
    # "What the data has").
    OTHER = "_$!<Other>!$_" #: String

    # The words the editor offers in a typed row's label field: the
    # type words and Apple's Other.
    #: (String name) -> Array[String]
    def self.typed_words(name) = [*TYPE_WORDS.fetch(name).keys, "other"]

    # An address as the lines a card carries it in, rendered through
    # #labeled_lines: a label of type words whole as TYPE values, any
    # other under an `item` group beside an X-ABLabel, and none as a
    # bare line. The group is numbered past every group `card` already
    # names (VCard#free_group), so a rendered label can never pair with
    # a line the stored card carries — the numbering the composition
    # owes a lent label (docs/plans/2026-10-25-contacts-on-entities.md,
    # "Composition"). Composition calls this one address at a time over
    # the card it has composed so far, so each label takes its own
    # group.
    #: (VCard card, Address address) -> Array[String]
    def self.address_lines(card, address)
      value = [address.po_box, address.extended, address.street, address.locality,
               address.region, address.postal_code, address.country].map { |component|
        VCard.escape(component)
      }.join(";")
      property = VCard::Parser::Property.new(group: nil, name: "ADR", parameters: [], value: "")
      labeled_lines(card, property, [], value, address.label.to_s)
    end

    # A typed row — a phone, an email — rewritten into the card under
    # `value`, its value already in the line's spelling.
    # A label that is nil or says what the row read leaves the header
    # alone, byte for byte; any other takes off what the reader showed
    # and writes the new word (#labeled_lines).
    #: (VCard card, Phone | Email row, String value, String? label) -> VCard
    def self.edited_row(card, row, value, label)
      if label.nil? || label == row.label.to_s.strip
        return card.substitute(row.line.digest, ["#{VCard.header_of(row.property)}#{value}"])
      end

      label_line = row.label_line
      card = card.substitute(label_line.digest, []) if label_line
      card.substitute(row.line.digest, labeled_lines(card, row.property, row.types, value, label))
    end

    # An added typed row's lines into the card, a bare line of `name`
    # under its label.
    #: (VCard card, String name, String value, String? label) -> VCard
    def self.added_row(card, name, value, label)
      property = VCard::Parser::Property.new(group: nil, name:, parameters: [], value: "")
      card.insert(labeled_lines(card, property, [], value, label.to_s))
    end

    # A phone's or an email's edit, one text value: a blank removes
    # the row, a changed one re-escapes from the form, and an unchanged
    # one under a new label keeps its bytes.
    #: (VCard card, Phone | Email row, String? label, Hash[String, String] fields) -> VCard
    def self.edited_value(card, row, label, fields)
      submitted = fields.fetch("value")
      return removed_row(card, row) if submitted.empty?

      edited_row(card, row, submitted == row.value.strip ? row.property.value : VCard.escape(submitted), label)
    end

    # An added phone or email, nothing for a blank one: inserting
    # absence is a no-op (docs/plans/2026-09-05-web-card-editor.md).
    #: (VCard card, String name, String? label, Hash[String, String] fields) -> VCard
    def self.added_value(card, name, label, fields)
      value = fields.fetch("value")
      value.empty? ? card : added_row(card, name, VCard.escape(value), label)
    end

    # A typed row's lines gone from the card: its own, and the
    # `X-ABLabel` sharing its group, which would otherwise be left
    # naming nothing (docs/plans/2026-10-22-a-row-edits-its-label.md,
    # "Removing a row removes its label").
    #: (VCard card, Phone | Email row) -> VCard
    def self.removed_row(card, row)
      card = card.substitute(row.line.digest, [])
      label_line = row.label_line
      label_line ? card.substitute(label_line.digest, []) : card
    end

    # The line of `property` under `value` and the label `label`, and
    # the X-ABLabel beside it where the label needs one. The types the
    # reader showed (`shown`) come off and every other parameter stays
    # — `pref`, the defaults the reader hides — so a relabel removes
    # exactly what the field rendered. A label every comma-separated
    # word of which is a type word goes in as TYPE values; any other
    # goes in an X-ABLabel under the line's group, or the card's
    # lowest free one (VCard#free_group). Blank writes neither.
    #: (VCard card, VCard::Parser::Property property, Array[String] shown, String value, String label) -> Array[String]
    def self.labeled_lines(card, property, shown, value, label)
      kept = property.parameters.reject { |name, type| name.casecmp?("TYPE") && shown.include?(type.downcase) }
      words = label.split(",").map(&:strip).reject(&:empty?)
      none = {} #: Hash[String, String]
      types = TYPE_WORDS.fetch(property.name.upcase, none)
      if words.all? { types.key?(it.downcase) }
        typed = words.map { ["TYPE", types.fetch(it.downcase)] } #: Array[[String, String]]
        line = VCard::Parser::Property.new(group: property.group, name: property.name, parameters: [*kept, *typed], value:)
        return ["#{VCard.header_of(line)}#{value}"]
      end

      group = property.group || card.free_group
      text = label.casecmp?("other") ? OTHER : VCard.escape(label)
      line = VCard::Parser::Property.new(group:, name: property.name, parameters: kept, value:)
      ["#{VCard.header_of(line)}#{value}", "#{group}.X-ABLabel:#{text}"]
    end

    private_class_method :labeled_lines

    # The card's ADRs as components, and the card without them — the
    # reading half of #address_lines, and the one walk every arrival
    # takes: a card a client submits (EditedContact), a card an import
    # composes (#of_card), and the migration that moved every ADR off
    # the stored bytes. Each address takes the `X-ABLabel` paired to
    # its group with it, the pairing #label_of reads, so a label never
    # names a line that stayed behind; a label no address took stays
    # in the card, naming a line of its own. An ADR that reads as no
    # address at all — blank throughout, po box included — is left in
    # the card as it lies: it holds nothing to move, and the bytes are
    # served either way, the parser's own posture. A line that would
    # not read stays for the same reason.
    #: (VCard card) -> [Array[Address], VCard]
    def self.take_addresses(card)
      labels = card.lines.filter_map { |line|
        property = line.property
        next if property.nil? || !property.name.casecmp?("X-ABLABEL") || property.group.nil?

        [property.group.downcase, line] #: [String, VCard::Parser::Line]
      }.to_h
      addresses = [] #: Array[Address]
      taken = [] #: Array[VCard::Parser::Line]
      card.lines.each do |line|
        next unless line.names?("ADR")

        property = line.property
        next if property.nil?

        label_line = property.group && labels[property.group.downcase]
        address = address_of(property, label_line)
        next if address.nil?

        addresses << address
        taken << line
        taken << label_line if label_line
      end
      [addresses, VCard.new(card.lines.reject { |line| taken.any? { it.equal?(line) } }.map(&:verbatim).join)]
    end

    # The card's NOTEs as the one note the model holds, and the card
    # without them: several join at a blank line — foreign input's
    # answer under the one-note invariant
    # (docs/plans/2026-09-25-one-note-per-contact.md, "The invariant")
    # — and a note that reads as no text, like one that would not
    # read, stays in the card as it lies: it holds nothing to move,
    # and the bytes are served either way.
    #: (VCard card) -> [String?, VCard]
    def self.take_note(card)
      notes = card.lines.select { it.names?("NOTE") }
      return [nil, card] if notes.empty?

      texts = [] #: Array[String]
      taken = [] #: Array[VCard::Parser::Line]
      notes.each do |line|
        property = line.property
        next if property.nil?

        text = property.text
        next if text.empty?

        texts << text
        taken << line
      end
      note = texts.empty? ? nil : texts.join("\n\n")
      [note, VCard.new(card.lines.reject { |line| taken.any? { it.equal?(line) } }.map(&:verbatim).join)]
    end

    # A card a PUT or an import arrived with, read as the details of
    # the contact it would store: its addresses and note taken off it,
    # the rest its stored card. What a group lends plays no part — a
    # contact being created has nothing lent, and a submitted card's
    # lent lines are struck before this walks what is left
    # (EditedContact).
    #: (card: VCard, birthday: Birthday?, ?lent: Array[Lent]) -> ContactDetails
    def self.of_card(card:, birthday:, lent: [])
      addresses, stored = take_addresses(card)
      note, stored = take_note(stored)
      new(stored:, birthday:, addresses:, note:, lent:)
    end

    # The Phone, Email, and Handle classes answer the editor the same
    # three things — its label, its fields by form name, and itself
    # rewritten into a card — and each writes an added one, so the
    # save walks every kind alike; the difference between them is
    # where each writes its label
    # (docs/plans/2026-10-22-a-row-edits-its-label.md, "The row writes
    # its own label"). The address is not one of these: it is a
    # component rather than a card line, and the editor writes it
    # through Admin::CardForm.addresses.
    class Phone
      #: () -> Array[String]
      def self.label_words = ContactDetails.typed_words("TEL")

      #: () -> Array[String]
      def self.field_names = %w[value]

      #: () -> String?
      def label = ContactDetails.label_of(label_line, types)

      #: () -> Hash[String, String]
      def fields = {"value" => value}

      #: (VCard card, String? label, Hash[String, String] fields) -> VCard
      def edit(card, label, fields)
        ContactDetails.edited_value(card, self, label, fields)
      end

      #: (VCard card, String? label, Hash[String, String] fields) -> VCard
      def self.add(card, label, fields)
        ContactDetails.added_value(card, "TEL", label, fields)
      end
    end

    class Email
      #: () -> Array[String]
      def self.label_words = ContactDetails.typed_words("EMAIL")

      #: () -> Array[String]
      def self.field_names = %w[value]

      #: () -> String?
      def label = ContactDetails.label_of(label_line, types)

      #: () -> Hash[String, String]
      def fields = {"value" => value}

      #: (VCard card, String? label, Hash[String, String] fields) -> VCard
      def edit(card, label, fields)
        ContactDetails.edited_value(card, self, label, fields)
      end

      #: (VCard card, String? label, Hash[String, String] fields) -> VCard
      def self.add(card, label, fields)
        ContactDetails.added_value(card, "EMAIL", label, fields)
      end
    end

    class Handle
      # Signal, the one service this server writes
      # (docs/plans/2026-10-18-signal-handles.md); any other is typed.
      #: () -> Array[String]
      def self.label_words = %w[signal]

      #: () -> Array[String]
      def self.field_names = %w[value]

      # A handle's word is its service, the column the record card has
      # always shown it in.
      #: () -> String?
      def label = service

      #: () -> Hash[String, String]
      def fields = {"value" => value}

      # A blank handle removes the line, a service alone being nothing
      # to reach anyone at. A changed handle under an unchanged service
      # swaps under the line's own header and scheme, the phones' rule;
      # a changed service rewrites the header around the line's other
      # parameters and moves the handle under `x-apple:`, the line's old
      # scheme naming the old service's protocol
      # (docs/plans/2026-10-18-signal-handles.md, "The service is the
      # row's").
      #: (VCard card, String? label, Hash[String, String] fields) -> VCard
      def edit(card, label, fields)
        submitted = fields.fetch("value")
        return card.substitute(line.digest, []) if submitted.empty?

        written =
          if label.nil? || label == service.to_s.strip
            "#{VCard.header_of(property)}#{scheme}:#{VCard.escape(submitted)}"
          else
            ContactDetails.handle_line(label, submitted, property)
          end
        card.substitute(line.digest, [written])
      end

      #: (VCard card, String? label, Hash[String, String] fields) -> VCard
      def self.add(card, label, fields)
        value = fields.fetch("value")
        value.empty? ? card : card.insert([ContactDetails.handle_line(label.to_s, value)])
      end
    end

    # A handle's line in Contacts.app's spelling, the service in
    # X-SERVICE-TYPE and the handle under `x-apple:`
    # (docs/plans/2026-10-18-signal-handles.md), keeping the group and
    # the other parameters of the line it replaces, if any. A blank
    # service names none. The characters a parameter value cannot
    # carry, quoted or not (RFC 2425 section 5.8.2's QSAFE-CHAR), are
    # dropped; VCard.header_of quotes what needs it.
    #: (String service, String value, ?VCard::Parser::Property? replaced) -> String
    def self.handle_line(service, value, replaced = nil)
      service = service.gsub(/[\x00-\x1F\x7F"]/, "")
      kept = (replaced&.parameters || []).reject { |name, _| name.casecmp?("X-SERVICE-TYPE") }
      parameters = service.empty? ? kept : [*kept, ["X-SERVICE-TYPE", service]] #: Array[[String, String]]
      property = VCard::Parser::Property.new(group: replaced&.group, name: "IMPP", parameters:, value: "")
      "#{VCard.header_of(property)}x-apple:#{VCard.escape(value)}"
    end

    #: (VCard vcard) -> String
    def self.etag_for(vcard)
      %("#{Digest::SHA256.hexdigest(vcard.to_s)}")
    end

    # The details from a stored card, a birthday, and the components
    # the entity holds. Why `birthday:` and the rest are required and
    # carry no default, and why the card is `stored:` rather than
    # `vcard:`, is docs/plans/2026-09-05-contact-takes-its-structure.md,
    # "The contracts".
    #: (stored: VCard, birthday: Birthday?, addresses: Array[Address], note: String?, lent: Array[Lent]) -> void
    def initialize(stored:, birthday:, addresses:, note:, lent:)
      @stored = stored
      @birthday = birthday
      @addresses = addresses
      @note = note
      @lent = lent
    end

    # The stored card, without the addresses, the note, or the birthday
    # composed in — the editor's handle on the bytes it mutates
    # (docs/plans/2026-09-05-web-card-editor.md). The readings answer
    # from it; what a client downloads is #vcard, composed.
    attr_reader :stored

    # The model held beside the card (see the class comment) — the
    # store's fact, not a parse of the served one. Nil over a card
    # carrying an unmodeled BDAY spelling; showing that is
    # #properties' job.
    attr_reader :birthday

    # The addresses the entity holds, its own — the group's are
    # #lent's. What a save writes (Admin::CardForm.addresses) and what
    # the editor renders over (ContactDetails#own).
    attr_reader :addresses

    # The note the entity holds, its own — the one note a contact is
    # (docs/plans/2026-09-25-one-note-per-contact.md), the member's
    # half of what #vcard composes.
    attr_reader :note

    # What the contact's groups lend it: each lending group, its
    # addresses at their positions and its note — what a submitted card
    # is measured against to tell a member's edit to a shared address
    # or note from one of its own (EditedContact).
    attr_reader :lent

    # The card to serve: the stored one with the addresses — the
    # entity's own first, then each group's in lending order — the one
    # NOTE, and the birthday composed in, each immediately before
    # END:VCARD. A labeled address composes under an `item` group of
    # its own (#address_lines), numbered past every group the stored
    # card already uses, so a lent label can never pair with the
    # member's own line. The NOTE is the member's own text and a
    # labeled section per group that lends one
    # (docs/plans/2026-09-25-one-note-per-contact.md). A birthday with
    # no wire form, or none at all, and no addresses and no note leave
    # their halves as they lie, and an empty insert is #insert's own
    # no-op — the same card object — so a contact holding nothing
    # serves exactly its stored bytes, etag included. Composed on first
    # ask and memoized, and the etag's derivation deferred with it: a
    # caller that reads neither — and the listing paths read neither —
    # pays for no composition of its own.
    #: () -> VCard
    def vcard
      return @vcard if defined?(@vcard)

      composed = @stored
      addresses_in_order.each { |address| composed = composed.insert(ContactDetails.address_lines(composed, address)) }
      note = composed_note
      replaced = note ? composed.replace("NOTE", [note]) : composed
      line = @birthday && @birthday.to_line
      inserted = line ? [line] : [] #: Array[String]
      @vcard = replaced.insert(inserted)
    end

    # Every address the contact serves, its own first and then each
    # group's, each carrying the group that lends it on `lent_by` —
    # the read the contact's page and the search walk, over the
    # components rather than the composed bytes, so a row and its
    # provenance cannot drift apart.
    #: () -> Array[Address]
    def served_addresses
      @addresses + @lent.flat_map { |lent|
        lent.addresses.map { it.address.with(lent_by: lent.group) }
      }
    end

    # The same details with nothing its groups lend it: the editor's
    # subject, because a form rendered from the composed contact would
    # save a group's value into the member's own — the materialization
    # the composition exists to avoid
    # (docs/plans/2026-08-24-vcard-storage-and-groups.md). The etag is
    # not this one's: a screen guarding a save still carries the
    # composed one, which is what a client downloads and what the
    # store's change log records.
    #: () -> ContactDetails
    def own
      return @own if defined?(@own)

      @own = ContactDetails.new(stored: @stored, birthday: @birthday, addresses: @addresses,
                                note: @note, lent: [])
    end

    # The same details over another card and birthday, still lent what
    # the groups lend: what an import proposes this contact become
    # (Import::Merge), the card and the components the proposal holds
    # — the card's own ADRs and NOTE have joined the entity's, the way
    # a save writes them. An entity-less proposal: Contact keeps its
    # id, and only the store makes one of those.
    #: (stored: VCard, birthday: Birthday?, addresses: Array[Address], note: String?) -> ContactDetails
    def with(stored:, birthday:, addresses:, note:)
      ContactDetails.new(stored:, birthday:, addresses:, note:, lent: @lent)
    end

    #: () -> String
    def etag
      return @etag if defined?(@etag)

      @etag = ContactDetails.etag_for(vcard)
    end

    # What a console session sees for one (console.rb): the default
    # would carry the stored card's whole bytes through @stored, which
    # makes a listing unreadable at a prompt. #name parses the card; no
    # app path inspects a details, so the parse is a session's price
    # alone.
    #: () -> String
    def inspect
      parts = [] #: Array[String]
      parts << "name=#{name.inspect}" if name
      "#<#{self.class.name} #{parts.join(" ")}>"
    end

    # The image formats a decoded PHOTO is recognized by, prefix to
    # mime type. A picture's type is read off the decoded bytes rather
    # than the TYPE parameter because magic bytes cannot mislabel what
    # they are and no allowlist of client spellings has to be kept;
    # binary literals, because the decoded payload is.
    PHOTO_SIGNATURES = [
      ["\xFF\xD8\xFF".b, "image/jpeg"],
      ["\x89PNG\r\n\x1A\n".b, "image/png"],
      ["GIF87a".b, "image/gif"],
      ["GIF89a".b, "image/gif"],
    ].freeze #: Array[[String, String]]

    # The picture the card carries, when it carries one a browser can
    # show: PHOTO's value base64-decoded and named by its own magic
    # bytes. The inline spelling is the one macOS sends; a URI-form
    # PHOTO never reaches the sniff, because a URI's ":" is not in
    # base64's alphabet and the strict decode refuses it. Nil for no
    # PHOTO, an undecodable one, or one that sniffs to no known format
    # — the initials an avatar falls back to, an ordinary absence
    # rather than an error, exactly like the other accessors' nils.
    # The two failures among those nils report on the way there —
    # warning-grade, carrying no card content — because a PHOTO this
    # server cannot read is news either way it fails: a decode
    # refusal could be the URI form, legal vCard (RFC 2426 section
    # 3.1.4) that no client here sends yet, and a decode that sniffs
    # to nothing is either junk that happened to decode or an image
    # format the signature list does not cover yet. At the read
    # rather than the arrival, unlike the parser's
    # reports (Web#report_broken_assumptions): no arrival probe reads
    # PHOTO, and a stored card can predate the report, while the
    # decode runs only where an avatar renders and Sentry groups the
    # repeats into one issue.
    #: () -> Photo?
    def photo
      property = stored.property("PHOTO")
      return if property.nil?

      begin
        bytes = Base64.strict_decode64(property.value)
      rescue ArgumentError => error
        Sentry.capture_exception(error, level: :warning)
        return
      end

      picture = ContactDetails.photo_of(bytes)
      if picture.nil?
        Sentry.capture_message(
          "a card's PHOTO decoded to no image format this server recognizes",
          level: :warning,
        )
      end
      picture
    end

    # Whether the card carries a picture an avatar should ask the photo
    # route for: #photo's answer read off the first bytes alone
    # (ContactDetails.photo_head?).
    #: () -> bool
    def photo?
      value = stored.property("PHOTO")&.value
      !value.nil? && ContactDetails.photo_head?(value)
    end

    # Base64 characters enough to decode past the longest signature:
    # twelve bytes, four characters to every three.
    PHOTO_HEAD = 16 #: Integer

    # Whether a PHOTO value's first characters decode to an image's
    # magic bytes, the only bytes the sniff looks at. The rest of the
    # payload is not decoded, so a PHOTO broken past them renders as an
    # image the photo route then refuses: the price of not decoding
    # every picture on a page to draw a list of them. A value cut to
    # PHOTO_HEAD reads the same, which is what lets the index hand over
    # no more of one (Store#listed_contacts).
    #: (String value) -> bool
    def self.photo_head?(value)
      head = Base64.strict_decode64(value[0, PHOTO_HEAD].to_s)
      PHOTO_SIGNATURES.any? { head.start_with?(it.first) }
    rescue ArgumentError
      false
    end

    # Bytes as a picture a browser can show, named by its magic
    # bytes (PHOTO_SIGNATURES), or nil for a format the list does not
    # cover. A card's PHOTO and a group's upload are judged alike.
    #: (String bytes) -> Photo?
    def self.photo_of(bytes)
      signature = PHOTO_SIGNATURES.find { bytes.start_with?(it.first) }
      Photo.new(mime_type: signature.fetch(1), bytes:) if signature
    end

    # The substrate the typed accessors sit on, and the read for what
    # none of them models — over the *composed* card, what a client
    # downloads: the composed ADRs are here, which is how an import's
    # held? sees the addresses the entity already holds (Import::Merge).
    #: () -> Array[VCard::Parser::Property]
    def properties = vcard.properties

    private

    # The addresses in the order the composition renders them: the
    # entity's own, then each group's in lending order.
    #: () -> Array[Address]
    def addresses_in_order
      @addresses + @lent.flat_map { |lent| lent.addresses.map { |row| row.address } }
    end

    # The one NOTE the served card carries, as a content line: the
    # member's own text and the lent notes as sections, written
    # through NoteSections and escaped the way the editors write a
    # text value, with no terminator so it takes the one of the line
    # it lands beside. Nil where the entity holds no note and nothing
    # is lent — nothing to compose. A stored card may still carry a
    # NOTE line that would not read (#take_note's reason for leaving
    # it); the replace below takes it with it, so the served card
    # carries the one NOTE wherever the model holds one at all — the
    # invariant's own bargain (docs/plans/2026-09-25-one-note-per-
    # contact.md, "The invariant").
    #: () -> String?
    def composed_note
      sections = @lent.filter_map { |lent|
        lent.note && NoteSections::Section.new(label: lent.group.label, text: lent.note)
      }
      member = @note.to_s
      return if member.empty? && sections.empty?

      "NOTE:#{VCard.escape(NoteSections.join(member, sections))}"
    end

    # An ADR as the component the entity holds, or nil where the value
    # reads as no address at all — blank throughout, the reader's own
    # rule for an ADR (Admin::CardForm's blank-equals-absent). The
    # components read unescaped, the value's reading rather than its
    # bytes; the label is #label_of's reading of the line, so a
    # component round-trips through #address_lines keeping what it
    # says and not how it was spelled.
    #: (VCard::Parser::Property property, VCard::Parser::Line? label_line) -> Address?
    def self.address_of(property, label_line)
      components = property.components
      return if components.all?(&:empty?)

      components << "" while components.length < 7
      Address.new(
        po_box: components.fetch(0), extended: components.fetch(1), street: components.fetch(2),
        locality: components.fetch(3), region: components.fetch(4), postal_code: components.fetch(5),
        country: components.fetch(6),
        label: label_of(label_line, property.types),
      )
    end
  end
end
