require "pro_tacts/contact"
require "pro_tacts/vcard"

module ProTacts
  # A contact as a list shows it: what a row, a sort, or a search reads
  # off one, built from the index (Store#listed_contacts) rather than
  # from the card's bytes. A list of contacts would otherwise parse
  # every card it draws, a picture's whole payload included, to show a
  # name beside an avatar.
  #
  # Its readings are the card's own, over the index's card — the rows
  # written back out with the PHOTO left out — through ContactReadings,
  # the same module ContactDetails reads, so a row and the contact's
  # page cannot disagree about a name, a phone, or a label. That card
  # is not the stored one: its bytes and its etag describe nothing a
  # client is served, so this answers neither, and nothing that writes
  # or guards a write takes one. Whether there is a picture is read
  # from the first bytes the index holds of it
  # (ContactDetails.photo_head?).
  class ListedContact
    # @rbs @contact: Contact
    # @rbs @photo: bool
    # @rbs @sort_key: String?

    include ContactReadings

    #: (Contact contact, photo: bool) -> void
    def initialize(contact, photo:)
      @contact = contact
      @photo = photo
    end

    #: () -> String
    def id = @contact.id

    # The index's reading of the card, the half the readings walk.
    #: () -> VCard
    def stored = @contact.stored

    # Kept, since a sort asks at every comparison; nothing writes
    # through a listed contact to change it. The inner contact's, for
    # its id behind the name — the module's own reading has no id to
    # fall back to.
    #: () -> String
    def sort_key = @sort_key ||= @contact.sort_key

    #: (Contact | ListedContact other) -> Integer?
    def <=>(other)
      [sort_key, id] <=> [other.sort_key, other.id]
    end

    #: () -> Birthday?
    def birthday = @contact.birthday

    # Over the composed card, the details' own read; the fallback
    # BDAY it looks for stays in the card the index wrote.
    #: () -> Array[VCard::Parser::Property]
    def properties = @contact.properties

    #: () -> Array[ContactDetails::Address]
    def addresses = @contact.served_addresses

    #: () -> Array[ContactDetails::Address]
    def served_addresses = @contact.served_addresses

    #: () -> String?
    def note = @contact.note

    #: () -> Array[ContactDetails::Lent]
    def lent = @contact.lent

    #: () -> bool
    def photo? = @photo

    #: () -> String
    def inspect
      "#<#{self.class.name} id=#{id.inspect}#{" name=#{name.inspect}" if name}>"
    end
  end
end
