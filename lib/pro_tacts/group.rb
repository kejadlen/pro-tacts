require "digest"
require "json"

require "pro_tacts/contact"
require "pro_tacts/vcard"

module ProTacts
  # A group as the admin screens read one: its own row, the addresses
  # and note it lends, its members' card ids, and whether it has a
  # photo (docs/plans/2026-10-12-group-photos.md). The label is the
  # SQL one Store#group_label computes, so a tag and a heading can
  # never disagree about what to call a nameless group. The addresses
  # and the note are the entity's components
  # (docs/plans/2026-10-25-contacts-on-entities.md): a group lends
  # what its entity holds, read beside the row the way a contact's
  # are.
  #
  # The signature lives in sig/pro_tacts/group.rbs, this being a Data
  # class.
  # @rbs skip
  Group = Data.define(:id, :name, :label, :addresses, :note, :members, :photo)

  # Reopened rather than defined in the block above, for the reason
  # CardDiff is.
  class Group
    # An address or a note is the exception, not the rule, so a group
    # built without saying is one holding neither, and without a photo
    # one.
    #: (?addresses: Array[Contact::Address], ?note: String?, ?photo: bool, **untyped) -> void
    def initialize(addresses: [], note: nil, photo: false, **)
      super
    end

    # The group names that choose what a client syncs: `sync:*` for
    # everyone, `sync:<login>` for one user
    # (docs/plans/2026-09-12-per-user-books.md). Unique like every
    # group's name (db/migrations/008_group_names.rb).
    SYNC_PREFIX = "sync:" #: String
    EVERYONE = "#{SYNC_PREFIX}*" #: String

    # Whether a group of this name chooses what a client syncs. Said of
    # a name rather than a group, because the store asks it of a row
    # and of a name a rename is about to write.
    #: (String? name) -> bool
    def self.sync_name?(name)
      name&.start_with?(SYNC_PREFIX) == true
    end

    # Whether this is one of the `sync:` groups, for the listings
    # that set those apart from the ones a person made.
    #: () -> bool
    def sync?
      Group.sync_name?(name)
    end

    # The addresses and the note as the lines a member's card composes
    # them in — the spelling the group's change log records a write in
    # (CardDiff's unit) and a tombstone carries. Numbered off a bare
    # card, a group having no stored card to number past.
    #: () -> Array[String]
    def composed_lines
      Group.composed_lines(addresses, note)
    end

    # The rendering half of #composed_lines over components a write is
    # about to hold, the way Contact.address_lines renders one address
    # at a time over the card composed so far.
    #: (Array[Contact::Address] addresses, String? note) -> Array[String]
    def self.composed_lines(addresses, note)
      card = VCard.new("BEGIN:VCARD\r\nVERSION:3.0\r\nEND:VCARD\r\n")
      lines = [] #: Array[String]
      addresses.each do |address|
        added = Contact.address_lines(card, address)
        lines.concat(added)
        card = card.insert(added)
      end
      lines << "NOTE:#{VCard.escape(note)}" if note
      lines
    end

    # The order every listing of groups reads in: the `sync:` groups
    # — the books a client syncs, the store's own rather than
    # anything a person made — first, then the rest alphabetically,
    # and the nameless ones last, their ids being no names to read.
    # GroupChoice spells this again for the pickers; keep the two
    # alike. Comparable deliberately left out: its `==` would sit in
    # front of Data's whole-value one, and `sort` asks only for `<=>`.
    #: (Group other) -> Integer?
    def <=>(other)
      [sync? ? 0 : 1, name.nil? ? 1 : 0, label.downcase, id] <=>
        [other.sync? ? 0 : 1, other.name.nil? ? 1 : 0, other.label.downcase, other.id]
    end

    # The group's etag, for the editor's snapshot guard: a hash of
    # everything the edit screen shows and the save writes, so a
    # group edited since the page loaded refuses the stale save
    # rather than reverting what changed (Web#apply_edit's rule).
    # Nothing serves it, so nothing has to agree with it but the form.
    #: () -> String
    def version
      Digest::SHA256.hexdigest([name, addresses, note, members].to_json)
    end

    # What a console session sees for one (console.rb): the Data
    # class's own inspect would carry every lent address and every
    # member id, and a listing of groups is unreadable at a prompt.
    #: () -> String
    def inspect
      "#<#{self.class.name} id=#{id.inspect} label=#{label.inspect} members=#{members.length}>"
    end
  end
end
