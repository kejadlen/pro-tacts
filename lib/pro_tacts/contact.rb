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
  # it.
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
    # Phone also carries `line`, the parsed line its value was read
    # from: the address a save names that phone's row by
    # (docs/plans/2026-09-05-web-card-editor.md) — the accessors fold
    # lines into typed values, and without provenance no form could
    # say "edit this phone." Email and Address gain their own with
    # their stage.
    # Data classes, whose members the inline syntax cannot read; the
    # signatures live in sig/pro_tacts/contact.rbs.
    # @rbs skip
    Phone = Data.define(:value, :type, :line)
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

    # A contact from its id, its stored card, and its birthday. The
    # only way to make one: an etag that came from anywhere but the
    # card in hand is an etag that can be wrong, and a birthday from
    # anywhere but the store is wrong the same way — which is why
    # `birthday:` is required and carries no default, since an
    # optional nil would let a caller quietly get no birthday off a
    # card that has one. Named `stored:` rather than `vcard:` because
    # what #vcard returns is composed, and an argument that is not
    # what the reader hands back is a trap.
    #: (id: String, stored: VCard, birthday: Birthday?) -> Contact
    def self.for(id:, stored:, birthday:)
      raise ArgumentError, "invalid contact id: #{id}" unless id.match?(ID_FORMAT)

      new(id, stored, birthday)
    end

    #: (VCard vcard) -> String
    def self.etag_for(vcard)
      %("#{Digest::SHA256.hexdigest(vcard.to_s)}")
    end

    #: (String id, VCard stored, Birthday? birthday) -> void
    def initialize(id, stored, birthday)
      @id = id
      @stored = stored
      @birthday = birthday
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

    # The card to serve: the stored one with the birthday composed back
    # in, immediately before END:VCARD — the same insert over the same
    # two inputs Store composed at each read path before, so the bytes
    # a client downloads do not move. A birthday with no wire form, or
    # none at all, serves the stored card exactly as it is. Composed on
    # first ask and memoized, and the etag's derivation deferred with
    # it: a caller that reads neither — and the listing paths read
    # neither — pays for no composition of its own.
    #: () -> VCard
    def vcard
      return @vcard if defined?(@vcard)

      line = @birthday && @birthday.to_line
      @vcard = line ? @stored.insert([line]) : @stored
    end

    # The etag over #vcard's bytes, derived here on first ask and
    # memoized with the card it hashes.
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

    # The card's properties — the substrate the typed accessors sit on,
    # and the read for what none of them models. Every line that read,
    # and no complaint about one that did not: a contact is served from
    # its bytes, so a line this parser cannot read costs an accessor its
    # answer and costs the contact nothing. There is no repair to make
    # and nobody to make it, which is why nothing here looks for one.
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
      of_line("TEL").filter_map do |line|
        property = line.property
        next if property.nil?

        value = text_of(property)
        Phone.new(value:, type: type_of(property), line:) if value
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
    # as no address at all.
    #: (VCard::Parser::Property property) -> Address?
    def address_of(property)
      components = components_of(property)
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
