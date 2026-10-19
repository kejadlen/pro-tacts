require "pro_tacts/contact"
require "pro_tacts/vcard"

module ProTacts
  # A contact as a list shows it: what a row, a sort, or a search reads
  # off one, built from the index (Store#listed_contacts) rather than
  # from the card's bytes. A list of contacts would otherwise parse
  # every card it draws, a picture's whole payload included, to show a
  # name beside an avatar.
  #
  # Its readings are Contact's own, over a card written back out of the
  # index's rows with the PHOTO left out, so a row and the contact's
  # page cannot disagree about a name, a phone, or a lent address. That
  # card is not the stored one: its bytes and its etag describe nothing
  # a client is served, so this answers neither, and nothing that
  # writes or guards a write takes one. Whether there is a picture is
  # read from the first bytes the index holds of it (Contact#photo?).
  class ListedContact
    # @rbs @contact: Contact
    # @rbs @photo: bool
    # @rbs @sort_key: String?

    #: (Contact contact, photo: bool) -> void
    def initialize(contact, photo:)
      @contact = contact
      @photo = photo
    end

    #: () -> String
    def id = @contact.id

    #: () -> String?
    def name = @contact.name

    #: () -> Array[String?]?
    def name_components = @contact.name_components

    #: () -> String?
    def nickname = @contact.nickname

    # Kept, since a sort asks at every comparison; nothing writes
    # through a listed contact to change it.
    #: () -> String
    def sort_key = @sort_key ||= @contact.sort_key

    #: (Contact | ListedContact other) -> Integer?
    def <=>(other)
      [sort_key, id] <=> [other.sort_key, other.id]
    end

    #: () -> String?
    def organization = @contact.organization

    #: () -> bool
    def company? = @contact.company?

    #: () -> Birthday?
    def birthday = @contact.birthday

    #: () -> Array[VCard::Parser::Property]
    def properties = @contact.properties

    #: () -> Array[Contact::Phone]
    def phones = @contact.phones

    #: () -> Array[Contact::Email]
    def emails = @contact.emails

    #: () -> Array[Contact::Address]
    def addresses = @contact.addresses

    #: () -> Array[Contact::Note]
    def notes = @contact.notes

    #: () -> bool
    def photo? = @photo

    #: () -> String
    def inspect
      "#<#{self.class.name} id=#{id.inspect}#{" name=#{name.inspect}" if name}>"
    end
  end
end
