require "digest"

module ProTacts
  # One contact: its id, the vCard bytes served for it, and the etag over
  # those bytes. The id is the vCard's UID and the name in its href (see
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
  # Stored and served are the same bytes today. Once a group contributes
  # properties at render time they will not be, and this becomes the hash
  # of the composed card — still derived, from more inputs.
  #
  # The signature lives in sig/pro_tacts/contact.rbs: a Data class has
  # no constant super class for the inline syntax to read.
  # @rbs skip
  class Contact < Data.define(:id, :vcard, :etag)
    # Ids end up in paths and arrive from client-supplied hrefs, so an id
    # outside this charset cannot be served.
    ID_FORMAT = /\A[\w-]+\z/

    # A contact from its id and its card. The only way to make one: an
    # etag that came from anywhere but the card in hand is an etag that
    # can be wrong.
    def self.for(id:, vcard:)
      raise ArgumentError, "invalid contact id: #{id}" unless id.match?(ID_FORMAT)

      new(id:, vcard:, etag: etag_for(vcard))
    end

    def self.etag_for(vcard)
      %("#{Digest::SHA256.hexdigest(vcard)}")
    end
  end
end
