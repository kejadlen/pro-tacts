require "pro_tacts/admin/format"

module ProTacts
  module Admin
    # What the header's search finds (docs/DESIGN.md: match generously —
    # by name, any of its values, and the groups a contact is in). A
    # query is words, and a record matches when every word turns up
    # somewhere in it, each word free to find a different field: "ada
    # london" is Ada with a London address. Every comparison is on
    # Format.search_key's fold of both sides, except a phone's, which
    # compares digits alone, since a number is spelled with whatever
    # punctuation its writer liked.
    #
    # Matching stays substring-generous rather than typo-tolerant: a
    # family's book is small enough to walk whole, and SQLite FTS5 was
    # weighed and set aside for it, twice (ranger pnrqpyvk, and
    # docs/plans/2026-10-17-search-keys.md). What is walked is each
    # contact's Key, folded when its card is written, rather than the
    # contacts themselves.
    module Search
      # The punctuation a phone number is written with, which a word made
      # of nothing else (and at least one digit) is a number spelled.
      PHONE_WORD = /\A[\d().+-]*\d[\d().+-]*\z/ #: Regexp
      private_constant :PHONE_WORD

      # A contact's values folded for matching, worked out once when its
      # card is written (Store#reindex) rather than on every search, so
      # a search reads three short columns and builds only the contacts
      # it finds. `text` is every text field (#text_fields) folded and
      # one to a line, `phones` each number's digits, a space between,
      # and `names` the name and nickname a name hit is read off. A word
      # is split on whitespace, so it cannot span the separator between
      # two values: a word found in the joined string is a word found in
      # one of them.
      #
      # A group's values are keyed the same way, at search time, from
      # what it lends (Group#reading) and its label: a contact is found
      # by those too, and keying them into each member would leave every
      # member's key to rewrite on a rename or a change to a lent line.
      # @rbs skip
      Key = Data.define(:text, :phones, :names)

      # A contact's key, read off its own card alone: what its groups
      # lend is matched as the group's (Key).
      #: (Contact | ListedContact contact) -> Key
      def self.key(contact)
        Key.new(
          text: text_fields(contact).map { Format.search_key(it) }.join("\n"),
          phones: contact.phones.map { digits(it.value) }.join(" "),
          names: [contact.name, contact.nickname].compact.map { Format.search_key(it) }.join(" "),
        )
      end

      # The ids of the contacts the query matches, in the order a search
      # is read: a hit on the name first — every word the start of a
      # word of the name or nickname, "ada" or "love" for Ada Lovelace —
      # then the hits anywhere else, recency keeping its order within
      # each. The rows arrive in recency order, and partition keeps it.
      # The groups arrive whole because a contact is found by the names
      # of the groups it is in and by what they lend it.
      #: (Array[Store::KeyedContact] rows, query: String, groups: Array[Group]) -> Array[String]
      def self.contacts(rows, query:, groups:)
        words = words(query)
        lent = {} #: Hash[String, Array[Key]]
        groups.each { |group|
          key = group_key(group)
          group.members.each { (lent[it] ||= []) << key }
        }
        matched = rows.select { |row| matches?([row.key, *lent.fetch(row.id, [])], words) }
        names, rest = matched.partition { name_hit?(it.key, words) }
        (names + rest).map(&:id)
      end

      # The groups whose names the query matches, every word somewhere
      # in the label, in the order Group sorts.
      #: (Array[Group] groups, query: String) -> Array[Group]
      def self.groups(groups, query:)
        words = words(query)
        groups.select { |group|
          label = Format.search_key(group.label)
          words.all? { label.include?(it) }
        }.sort
      end

      #: (String query) -> Array[String]
      def self.words(query)
        Format.search_key(query).split
      end
      private_class_method :words

      # What a group adds to each member's key: the lines it lends, read
      # as a card, and its label. A name it does not lend, so its key's
      # names stay its own and no member's name hit comes from a group.
      #: (Group group) -> Key
      def self.group_key(group)
        lent = key(group.reading)
        lent.with(text: [lent.text, Format.search_key(group.label)].join("\n"))
      end
      private_class_method :group_key

      #: (Array[Key] keys, Array[String] words) -> bool
      def self.matches?(keys, words)
        words.all? { |word|
          keys.any? { it.text.include?(word) } ||
            (word.match?(PHONE_WORD) && keys.any? { it.phones.include?(digits(word)) })
        }
      end
      private_class_method :matches?

      # Every value of the contact a word is matched against as text:
      # its names, organization, emails, addresses, and notes. An
      # address is its components run together, so "main st" finds a
      # street.
      #: (Contact | ListedContact contact) -> Array[String]
      def self.text_fields(contact)
        [
          contact.name,
          contact.nickname,
          contact.organization,
          *contact.emails.map(&:value),
          *contact.addresses.map { [it.extended, it.street, it.locality, it.region, it.postal_code, it.country].compact.join(" ") },
          *contact.notes.map(&:value),
        ].compact
      end
      private_class_method :text_fields

      #: (Key key, Array[String] words) -> bool
      def self.name_hit?(key, words)
        name_words = key.names.split
        words.all? { |word| name_words.any? { it.start_with?(word) } }
      end
      private_class_method :name_hit?

      #: (String value) -> String
      def self.digits(value)
        value.delete("^0-9")
      end
      private_class_method :digits
    end
  end
end
