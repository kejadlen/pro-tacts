require "base64"
require "digest"
require "sentry-ruby"

require "pro_tacts/birthday"
require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  # One contact: its id, the card served for it, and the etag over that
  # card's bytes — the one model of a contact
  # (docs/plans/2026-09-01-contact-is-the-model.md). The id is the
  # vCard's UID and the name in its href (see
  # docs/plans/2026-01-12-carddav-architecture.md).
  #
  # A VCard rather than the bytes, because a contact that held bytes
  # would have to make a card out of them to answer anything, and every
  # caller handing one over already had a card in hand to make the bytes
  # from. One card is built per contact and every read is asked of it.
  #
  # The card this holds is the stored one, and the birthday sits beside
  # it rather than being parsed back out of the card it was composed
  # into (docs/plans/2026-09-05-contact-takes-its-structure.md): Store's
  # write either moves a BDAY line into the model or leaves it in the
  # card, never both, so the two facts are independent and #vcard
  # composes the served card from them. An unmodeled BDAY spelling is
  # the card's own — #properties shows it, and #birthday reads nil over
  # it. The lines a contact inherits from its groups sit beside the
  # birthday the same way: no stored card carries them, so they are
  # store facts composed in at read
  # (docs/plans/2026-08-24-vcard-storage-and-groups.md).
  #
  # The etag hashes the card that goes out, so it changes exactly when
  # what the client downloads changes. It is derived here and stored
  # nowhere: a contact read back from the store hashes its card the same
  # way one about to be written does, which is why there is one
  # constructor rather than one that computes and one that trusts. It is
  # in the entity-tag's quoted form (RFC 7232 section 2.3), which is what
  # both the ETag header and getetag properties carry.
  #
  # The structured accessors are that idea applied to the card's
  # contents: everything else derives from the bytes, and the card defers
  # the walk that reads them until something asks. The CardDAV paths never
  # ask — they answer in bytes — so the serving paths pay for no parse
  # they do not use, and that laziness is VCard's to keep rather than
  # this class's to arrange.
  #
  # The accessors are deliberately shallow, like the parser: a card can
  # carry properties no accessor knows, and CardDAV still serves every
  # one. #properties is the read for those.
  class Contact
    # @rbs @id: String
    # @rbs @stored: VCard
    # @rbs @birthday: Birthday?
    # @rbs @inherited: Array[Inherited]
    # @rbs @vcard: VCard
    # @rbs @etag: String
    # @rbs @groups_by_line: Hash[String, String]

    # Ids end up in paths and arrive from client-supplied hrefs, so an id
    # outside this charset cannot be served.
    ID_FORMAT = /\A[\w-]+\z/ #: Regexp

    # The structured shapes the accessors return: text value and type
    # for TEL (RFC 2426 section 3.3.1) and EMAIL (section 3.3.2), and
    # ADR's seven components (section 3.2.1: post office box, extended
    # address, street, locality, region, postal code, country — nil
    # where the card left the position blank or stopped short of it).
    # Each also carries `line`, the parsed line the value was read
    # from: the address a save names that row by
    # (docs/plans/2026-09-05-web-card-editor.md) — the accessors fold
    # lines into typed values, and without provenance no form could
    # say "edit this phone."
    # Data classes, whose members the inline syntax cannot read; the
    # signatures live in sig/pro_tacts/contact.rbs.
    # @rbs skip
    Phone = Data.define(:value, :type, :line)
    # @rbs skip
    Email = Data.define(:value, :type, :line)
    # @rbs skip
    Note = Data.define(:value, :line)
    # @rbs skip
    Photo = Data.define(:mime_type, :bytes)

    # One line a group lends this contact, and the name of the group
    # that lends it. The name rather than the group itself, because
    # the name is the whole of what a card shows about it today and
    # nothing here can navigate to a record that has no screen yet
    # (docs/DESIGN.md, "Relationships are navigable").
    # @rbs skip
    Inherited = Data.define(:group, :line)
    # @rbs skip
    Address = Data.define(
      :po_box,
      :extended,
      :street,
      :locality,
      :region,
      :postal_code,
      :country,
      :type,
      :line,
    )

    #: (VCard vcard) -> String
    def self.etag_for(vcard)
      %("#{Digest::SHA256.hexdigest(vcard.to_s)}")
    end

    # A contact from its id, its stored card, its birthday, and the
    # content lines it inherits from its groups. An etag that came from
    # anywhere but the card in hand is an etag that can be wrong, and a
    # birthday or an inheritance from anywhere but the store is wrong
    # the same way — which is why `birthday:` and `inherited:` are
    # required and carry no defaults, since an optional nil would let a
    # caller quietly get no birthday off a card that has one, and an
    # omitted inheritance would serve a member its group's lines no
    # longer reach. Named `stored:` rather than `vcard:` because what
    # #vcard returns is composed, and an argument that is not what the
    # reader hands back is a trap.
    #
    # The id check is here rather than behind a factory: an id outside
    # ID_FORMAT cannot be served, and a guard a caller can walk around
    # by reaching for `new` is not a guard.
    #: (id: String, stored: VCard, birthday: Birthday?, inherited: Array[Inherited]) -> void
    def initialize(id:, stored:, birthday:, inherited:)
      raise ArgumentError, "invalid contact id: #{id}" unless id.match?(ID_FORMAT)

      @id = id
      @stored = stored
      @birthday = birthday
      @inherited = inherited
    end

    attr_reader :id

    # The stored card, without the birthday composed in — the editor's
    # handle on the bytes it mutates (docs/plans/2026-09-05-web-card-editor.md).
    # Everything else this class answers describes #vcard, the card a
    # client downloads; the stored one is what a surgical edit applies
    # to, and what the store writes back after it.
    attr_reader :stored

    # The model held beside the card (see the class comment) — the
    # store's fact, not a parse of the served one. Nil over a card
    # carrying an unmodeled BDAY spelling; showing that is
    # #properties' job.
    attr_reader :birthday

    # The card to serve: the stored one with the inherited lines and
    # the birthday composed back in, in that order, each immediately
    # before END:VCARD — stored + inherited + birthday, the card a
    # client downloads. A birthday with no wire form, or none at all,
    # and an empty inheritance leave their halves as they lie, and an
    # empty inheritance is #insert's own no-op — the same card object —
    # so a contact in no group serves exactly the bytes it did before
    # groups existed, etag included. Composed on first ask and
    # memoized, and the etag's derivation deferred with it: a caller
    # that reads neither — and the listing paths read neither — pays
    # for no composition of its own.
    #: () -> VCard
    def vcard
      return @vcard if defined?(@vcard)

      card = @stored.insert(@inherited.map { it.line })
      line = @birthday && @birthday.to_line
      @vcard = line ? card.insert([line]) : card
    end

    # The same contact with nothing its groups lend it: the editor's
    # subject, because a form rendered from the composed contact would
    # save a group's value into the member's own card — the
    # materialization the composition exists to avoid
    # (docs/plans/2026-08-24-vcard-storage-and-groups.md). The etag is
    # not this contact's: a screen guarding a save still carries the
    # composed one, which is what a client downloads and what the
    # store's change log records.
    #: () -> Contact
    def own
      return @own if defined?(@own)

      @own = self.class.new(id: @id, stored: @stored, birthday: @birthday, inherited: [])
    end

    #: () -> String
    def etag
      return @etag if defined?(@etag)

      @etag = self.class.etag_for(vcard)
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
      property = properties.find { it.name.casecmp?("PHOTO") }
      return if property.nil?

      begin
        bytes = Base64.strict_decode64(property.value)
      rescue ArgumentError => error
        Sentry.capture_exception(error, level: :warning)
        return
      end

      signature = PHOTO_SIGNATURES.find { bytes.start_with?(it.first) }
      if signature.nil?
        Sentry.capture_message(
          "a card's PHOTO decoded to no image format this server recognizes",
          level: :warning,
        )
        return
      end

      Photo.new(mime_type: signature.fetch(1), bytes:)
    end

    # The substrate the typed accessors sit on, and the read for what
    # none of them models.
    #: () -> Array[VCard::Parser::Property]
    def properties = vcard.properties

    # FN's value (RFC 2426 section 3.1.1), in text form.
    #: () -> String?
    def name
      text_of(properties.find { it.name.casecmp?("FN") })
    end

    # N's components (RFC 2426 section 3.1.2: family; given; additional;
    # prefixes; suffixes), split and unescaped, or nil with no N at all.
    # Structured data — reading initials off it is the real answer to
    # where a first/last split falls, rather than guessing in the
    # free-text FN.
    #: () -> Array[String?]?
    def name_components
      property = properties.find { it.name.casecmp?("N") }
      property && components_of(property)
    end

    # NICKNAME's value (RFC 2426 section 3.1.3), in text form — the
    # whole value, as the card spells it, when it comma-lists several.
    #: () -> String?
    def nickname
      text_of(properties.find { it.name.casecmp?("NICKNAME") })
    end

    #: () -> Array[Phone]
    def phones
      rows("TEL") { |property, line|
        value = text_of(property)
        Phone.new(value:, type: type_of(property), line:) if value
      }
    end

    #: () -> Array[Email]
    def emails
      rows("EMAIL") { |property, line|
        value = text_of(property)
        Email.new(value:, type: type_of(property), line:) if value
      }
    end

    #: () -> Array[Address]
    def addresses
      rows("ADR") { |property, line| address_of(property, line:) }
    end

    # The card's NOTEs (RFC 2426 section 3.6.2), in text form. Every
    # one, not the first: a member with a note of its own and a group
    # that lends it another carries two, and RFC 6350 section 6.7.2
    # settles that this is a card and not a broken one — NOTE's
    # cardinality is `*`, and 2426 restricts it nowhere. Showing one
    # would hide whichever the composition happened to put second,
    # which is always the group's (see #vcard).
    #: () -> Array[Note]
    def notes
      rows("NOTE") { |property, line|
        value = text_of(property)
        Note.new(value:, line:) if value
      }
    end

    # The name of the group a composed line came from, or nil for a
    # line the contact's own card carries — the provenance a screen
    # marks an inherited row with.
    #
    # Matched by the line's bytes, which is the same blindness the
    # editor's digests have (VCard::Parser::Line#digest): a stored
    # line whose bytes are a group's line reads as the group's here.
    # That state is a member's rewrite carrying an inherited line back
    # into its own card, which the write half subtracts
    # (docs/plans/2026-08-24-vcard-storage-and-groups.md); until it
    # lands, naming the group over both copies says something true
    # about the value even where it is wrong about the byte.
    #: (VCard::Parser::Line line) -> String?
    def group_of(line)
      groups_by_line[line.verbatim.chomp]
    end

    private

    # Every inherited line's group, keyed by the line's own bytes with
    # the terminator off — a group's line is stored without one and
    # composes with the card's, so neither side is compared as it lies.
    #: () -> Hash[String, String]
    def groups_by_line
      return @groups_by_line if defined?(@groups_by_line)

      @groups_by_line = @inherited.to_h {
        [it.line.chomp, it.group] #: [String, String]
      }
    end

    # The rows a repeatable property reads as: each line naming it
    # folded by the block, which answers nil for a row with nothing
    # to show.
    #: [T] (String name) { (VCard::Parser::Property, VCard::Parser::Line) -> T? } -> Array[T]
    def rows(name)
      of_line(name).filter_map { |line|
        property = line.property
        yield(property, line) unless property.nil?
      }
    end

    # The lines naming `name`, parsed beside their bytes — the walk the
    # provenance-carrying accessors read from, so a row can carry the
    # line it was read from as its address. A line that would not
    # read is a row no form can address and no accessor reads; it
    # stays enumerable in VCard#lines, served from its bytes.
    #: (String name) -> Array[VCard::Parser::Line]
    def of_line(name)
      vcard.lines.select { it.names?(name) }
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

    # ADR's components, with a value that is blank throughout reading
    # as no address at all. Carries the line it was read from, the
    # other provenance-carrying shapes' own address for a save.
    #: (VCard::Parser::Property property, line: VCard::Parser::Line) -> Address?
    def address_of(property, line:)
      components = components_of(property)
      return if components.none?

      po_box, extended, street, locality, region, postal_code, country = components
      Address.new(po_box:, extended:, street:, locality:, region:, postal_code:, country:, type: type_of(property), line:)
    end

    # RFC 2426 section 3.3.1. Downcased: the spelling is the card's,
    # and a screen shows one.
    #: (VCard::Parser::Property property) -> String?
    def type_of(property)
      property.parameter("TYPE")&.downcase
    end
  end
end
