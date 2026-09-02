require "digest"

require "pro_tacts/birthday"
require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  # One contact: its id, the vCard bytes served for it, the etag over
  # those bytes, and the structured read of them — the one model of a
  # contact (docs/plans/2026-09-01-contact-is-the-model.md). The id is
  # the vCard's UID and the name in its href (see
  # docs/plans/2026-01-12-carddav-architecture.md).
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
  # contents: everything derives from the bytes, lazily, on the first
  # structured read. The CardDAV paths never take one — they answer in
  # bytes — and ctag and the listing reads build a contact per row
  # without reading structure, so deferring the parse keeps every
  # serving path as cheap as it was without the accessors. A regular
  # class rather than a Data one because the memoized parse needs an
  # ivar and Data freezes its instances.
  #
  # The accessors are deliberately shallow, like the parser: a card can
  # carry properties no accessor knows, and CardDAV still serves every
  # one. #properties is the read for those.
  class Contact
    # @rbs @id: String
    # @rbs @vcard: String
    # @rbs @etag: String
    # @rbs @properties: Array[VCard::Property]

    # Ids end up in paths and arrive from client-supplied hrefs, so an id
    # outside this charset cannot be served.
    ID_FORMAT = /\A[\w-]+\z/ #: Regexp

    # The structured shapes the accessors return: text value and type
    # for TEL (RFC 2426 section 3.3.1) and EMAIL (section 3.3.2), and
    # ADR's seven components (section 3.2.1: post office box, extended
    # address, street, locality, region, postal code, country — nil
    # where the card's value stopped short of the position). Data
    # classes, whose members the inline syntax cannot read; the
    # signatures live in sig/pro_tacts/contact.rbs.
    # @rbs skip
    Phone = Data.define(:value, :type)
    # @rbs skip
    Email = Data.define(:value, :type)
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
    )

    # A contact from its id and its card. The only way to make one: an
    # etag that came from anywhere but the card in hand is an etag that
    # can be wrong.
    #: (id: String, vcard: String) -> Contact
    def self.for(id:, vcard:)
      raise ArgumentError, "invalid contact id: #{id}" unless id.match?(ID_FORMAT)

      new(id, vcard, etag_for(vcard))
    end

    #: (String vcard) -> String
    def self.etag_for(vcard)
      %("#{Digest::SHA256.hexdigest(vcard)}")
    end

    #: (String id, String vcard, String etag) -> void
    def initialize(id, vcard, etag)
      @id = id
      @vcard = vcard
      @etag = etag
    end

    attr_reader :id

    attr_reader :vcard

    attr_reader :etag

    # The card's properties, parsed once and memoized — the substrate
    # the typed accessors sit on, and the read for what none of them
    # models. Lets VCard::ParseError raise rather than returning an
    # empty card: PUT checks the card's envelope before the store
    # accepts it, so one reaching this unparseable is a bug or a
    # corrupt row, and Sentry (already wired into every request, see
    # ProTacts::Web) is where that should surface, not a silently
    # blank screen. VCard.new tolerates the same bytes for the paths
    # that serve them; this model of a served contact does not.
    #: () -> Array[VCard::Property]
    def properties
      return @properties if defined?(@properties)

      @properties = VCard::Parser.parse(@vcard)
    end

    # FN's value (RFC 2426 section 3.1.1), in text form.
    #: () -> String?
    def name
      property = properties.find { it.name.casecmp?("FN") }
      property && VCard.unescape(property.value)
    end

    # N's components (RFC 2426 section 3.1.2: family; given; additional;
    # prefixes; suffixes), split and unescaped, or nil with no N at all.
    # Structured data — reading initials off it is the real answer to
    # where a first/last split falls, rather than guessing in the
    # free-text FN.
    #: () -> Array[String]?
    def name_components
      property = properties.find { it.name.casecmp?("N") }
      property && VCard.split_components(property.value)
    end

    #: () -> Array[Phone]
    def phones
      of_name("TEL").map { Phone.new(value: VCard.unescape(it.value), type: type_of(it)) }
    end

    #: () -> Array[Email]
    def emails
      of_name("EMAIL").map { Email.new(value: VCard.unescape(it.value), type: type_of(it)) }
    end

    #: () -> Array[Address]
    def addresses
      of_name("ADR").map { address_of(it) }
    end

    # The birthday the served card carries — the model the store
    # composed into it (see Birthday), parsed back out because the two
    # forms Birthday serves are exactly the two from_property accepts.
    # Nil when the card carries no BDAY the model recomposes; an
    # unmodeled spelling stays in the card and is #properties' to show.
    #: () -> Birthday?
    def birthday
      property = properties.find { it.name.casecmp?("BDAY") }
      property && Birthday.from_property(property)
    end

    # The card's NOTE (RFC 2426 section 3.6.2), in text form.
    #: () -> String?
    def notes
      property = properties.find { it.name.casecmp?("NOTE") }
      property && VCard.unescape(property.value)
    end

    private

    #: (String name) -> Array[VCard::Property]
    def of_name(name)
      properties.select { it.name.casecmp?(name) }
    end

    #: (VCard::Property property) -> Address
    def address_of(property)
      po_box, extended, street, locality, region, postal_code, country =
        VCard.split_components(property.value)
      Address.new(po_box:, extended:, street:, locality:, region:, postal_code:, country:, type: type_of(property))
    end

    # RFC 2426 section 3.3.1: TYPE can repeat (TYPE=work;TYPE=voice) or
    # comma-list (TYPE=work,voice) — either arrives here as one
    # parameter per value, so the first is the one this carries.
    #: (VCard::Property property) -> String?
    def type_of(property)
      property.parameters.find { |name, _| name.casecmp?("TYPE") }&.last&.downcase
    end
  end
end
