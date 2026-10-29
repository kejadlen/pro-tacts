require "pro_tacts/contact_details"

module ProTacts
  # A contact: ContactDetails with the entity behind them — the id the
  # card goes by, the vCard's UID and the name in its href
  # (docs/plans/2026-01-12-carddav-architecture.md). Everything a
  # contact's details answer is the superclass's; what the subclass
  # adds is the identity, which is what the screens that link by
  # entity need and what an entity-less details cannot hand them —
  # the type checker keeps an import's preview out of those screens
  # (docs/plans/2026-10-25-contacts-on-entities.md, "The types").
  #
  # Only the store makes one: a Contact's components are the entity's
  # rows, and the store is the one reader of them that writes. A card
  # on its way in — an import's preview, a submission being read back
  # — is a ContactDetails until the store writes it.
  class Contact < ContactDetails
    # @rbs @id: String

    # Ids end up in paths and arrive from client-supplied hrefs, so an id
    # outside this charset cannot be served.
    ID_FORMAT = /\A[\w-]+\z/ #: Regexp

    # A contact from its id over the details the store read for it.
    # Why `birthday:` and the rest are required and carry no default,
    # and why the card is `stored:` rather than `vcard:`, is
    # docs/plans/2026-09-05-contact-takes-its-structure.md, "The
    # contracts".
    #
    # The id check is here rather than behind a factory: a guard a
    # caller can walk around by reaching for `new` is not a guard.
    #: (id: String, stored: VCard, birthday: Birthday?, addresses: Array[ContactDetails::Address], note: String?, lent: Array[ContactDetails::Lent]) -> void
    def initialize(id:, stored:, birthday:, addresses:, note:, lent:)
      raise ArgumentError, "invalid contact id: #{id}" unless id.match?(ID_FORMAT)

      @id = id
      super(stored:, birthday:, addresses:, note:, lent:)
    end

    attr_reader :id

    # The order a contact lists under, ContactReadings' with the id
    # behind it: N's family name, then FN, then the id for a card with
    # no name at all, the way Admin::Format.initials falls back.
    #: () -> String
    def sort_key
      family, = name_components || []
      (family || name || id).to_s.downcase
    end

    # Not Comparable, for Group#<=>'s reason.
    #: (Contact | ListedContact other) -> Integer?
    def <=>(other)
      [sort_key, id] <=> [other.sort_key, other.id]
    end

    # What a console session sees for one (console.rb): the default
    # would carry the stored card's whole bytes through @stored, which
    # makes a listing of contacts unreadable at a prompt.
    #: () -> String
    def inspect
      parts = ["id=#{id.inspect}"]
      parts << "name=#{name.inspect}" if name
      "#<#{self.class.name} #{parts.join(" ")}>"
    end
  end
end
