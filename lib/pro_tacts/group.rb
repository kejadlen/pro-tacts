require "digest"
require "json"

require "pro_tacts/contact"
require "pro_tacts/vcard"

module ProTacts
  # A group as the admin screens read one: its own row, the lines it
  # lends in the order it lends them, and its members' card ids. The
  # label is the SQL one Store#group_label computes, so a tag and a
  # heading can never disagree about what to call a nameless group.
  #
  # The signature lives in sig/pro_tacts/group.rbs, this being a Data
  # class.
  # @rbs skip
  Group = Data.define(:id, :name, :label, :lines, :members)

  # Reopened rather than defined in the block above, for the reason
  # CardDiff is.
  class Group
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

    # The group's lines read through the one model that knows how to
    # read an address and a note — a Contact over a card made of
    # those lines and nothing else — for the screens that render and
    # edit them. It composes nothing and is never stored or served.
    #: () -> Contact
    def reading
      Contact.new(id:, stored: VCard.new(lines.map { "#{it}\r\n" }.join), birthday: nil, inherited: [])
    end

    # Whether this is one of the `sync:` groups, for the listing that
    # sets those groups apart from the ones a person made
    # (Admin::GroupsIndex).
    #: () -> bool
    def sync?
      Group.sync_name?(name)
    end

    # The group's etag, for the editor's snapshot guard: a hash of
    # everything the edit screen shows and the save writes, so a
    # group edited since the page loaded refuses the stale save
    # rather than reverting what changed (Web#apply_edit's rule).
    # Nothing serves it, so nothing has to agree with it but the form.
    #: () -> String
    def version
      Digest::SHA256.hexdigest([name, lines, members].to_json)
    end

    # What a console session sees for one (console.rb): the Data
    # class's own inspect would carry every lent line and every
    # member id, and a listing of groups is unreadable at a prompt.
    #: () -> String
    def inspect
      "#<#{self.class.name} id=#{id.inspect} label=#{label.inspect} members=#{members.length}>"
    end
  end
end
