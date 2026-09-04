require "base64"
require "digest"

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
  # The etag hashes the card that goes out, so it changes exactly when
  # what the client downloads changes. It is derived here and stored
  # nowhere: a contact read back from the store hashes its card the same
  # way one about to be written does, which is why there is one
  # constructor rather than one that computes and one that trusts. It is
  # in the entity-tag's quoted form (RFC 7232 section 2.3), which is what
  # both the ETag header and getetag properties carry.
  #
  # The structured accessors are that idea applied to the card's
  # contents: everything derives from the bytes, and the card defers the
  # walk that reads them until something asks. The CardDAV paths never
  # ask — they answer in bytes — so the serving paths pay for no parse
  # they do not use, and that laziness is VCard's to keep rather than
  # this class's to arrange.
  #
  # The accessors are deliberately shallow, like the parser: a card can
  # carry properties no accessor knows, and CardDAV still serves every
  # one. #properties is the read for those.
  class Contact
    # @rbs @id: String
    # @rbs @vcard: VCard
    # @rbs @etag: String

    # Ids end up in paths and arrive from client-supplied hrefs, so an id
    # outside this charset cannot be served.
    ID_FORMAT = /\A[\w-]+\z/ #: Regexp

    # The structured shapes the accessors return: text value and type
    # for TEL (RFC 2426 section 3.3.1) and EMAIL (section 3.3.2), and
    # ADR's seven components (section 3.2.1: post office box, extended
    # address, street, locality, region, postal code, country — nil
    # where the card left the position blank or stopped short of it).
    # Data classes, whose members the inline syntax cannot read; the
    # signatures live in sig/pro_tacts/contact.rbs.
    # @rbs skip
    Phone = Data.define(:value, :type)
    # @rbs skip
    Email = Data.define(:value, :type)
    # @rbs skip
    Photo = Data.define(:mime_type, :bytes)
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
    #: (id: String, vcard: VCard) -> Contact
    def self.for(id:, vcard:)
      raise ArgumentError, "invalid contact id: #{id}" unless id.match?(ID_FORMAT)

      new(id, vcard, etag_for(vcard))
    end

    #: (VCard vcard) -> String
    def self.etag_for(vcard)
      %("#{Digest::SHA256.hexdigest(vcard.to_s)}")
    end

    #: (String id, VCard vcard, String etag) -> void
    def initialize(id, vcard, etag)
      @id = id
      @vcard = vcard
      @etag = etag
    end

    attr_reader :id

    attr_reader :vcard

    attr_reader :etag

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
    #: () -> Photo?
    def photo
      property = properties.find { it.name.casecmp?("PHOTO") }
      return if property.nil?

      begin
        bytes = Base64.strict_decode64(property.value)
      rescue ArgumentError
        return
      end

      signature = PHOTO_SIGNATURES.find { bytes.start_with?(it.first) }
      return if signature.nil?

      Photo.new(mime_type: signature.fetch(1), bytes:)
    end

    # The card's properties — the substrate the typed accessors sit on,
    # and the read for what none of them models. Every line that read,
    # and no complaint about one that did not: a contact is served from
    # its bytes, so a line this parser cannot read costs an accessor its
    # answer and costs the contact nothing. There is no repair to make
    # and nobody to make it, which is why nothing here looks for one.
    #: () -> Array[VCard::Parser::Property]
    def properties = @vcard.properties

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
      property && components_of(property.value)
    end

    #: () -> Array[Phone]
    def phones
      of_name("TEL").filter_map do |property|
        value = text_of(property)
        Phone.new(value:, type: type_of(property)) if value
      end
    end

    #: () -> Array[Email]
    def emails
      of_name("EMAIL").filter_map do |property|
        value = text_of(property)
        Email.new(value:, type: type_of(property)) if value
      end
    end

    #: () -> Array[Address]
    def addresses
      of_name("ADR").filter_map { address_of(it) }
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
      text_of(properties.find { it.name.casecmp?("NOTE") })
    end

    private

    #: (String name) -> Array[VCard::Parser::Property]
    def of_name(name)
      properties.select { it.name.casecmp?(name) }
    end

    # A text property's value, with the empty one reading as absent:
    # a property whose value carries nothing is one no caller has to
    # tell apart from a property that is not there.
    #: (VCard::Parser::Property? property) -> String?
    def text_of(property)
      return if property.nil?

      value = VCard.unescape(property.value)
      value.empty? ? nil : value
    end

    # A structured value's components, nil in the positions the card
    # left blank: an empty component is as absent as one past the end
    # of the value, and reads the same.
    #: (String value) -> Array[String?]
    def components_of(value)
      VCard.split_components(value).map { it.empty? ? nil : it }
    end

    # ADR's components, with a value that is blank throughout reading
    # as no address at all.
    #: (VCard::Parser::Property property) -> Address?
    def address_of(property)
      components = components_of(property.value)
      return if components.none?

      po_box, extended, street, locality, region, postal_code, country = components
      Address.new(po_box:, extended:, street:, locality:, region:, postal_code:, country:, type: type_of(property))
    end

    # RFC 2426 section 3.3.1: TYPE can repeat (TYPE=work;TYPE=voice) or
    # comma-list (TYPE=work,voice) — either arrives here as one
    # parameter per value, so the first is the one this carries.
    #: (VCard::Parser::Property property) -> String?
    def type_of(property)
      property.parameters.find { |name, _| name.casecmp?("TYPE") }&.last&.downcase
    end
  end
end
