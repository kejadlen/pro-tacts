require "json"

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
    # Matching stays substring-generous rather than typo-tolerant or
    # indexed: a family's book is small enough to walk whole, as Keys
    # folded when each card is written
    # (docs/plans/2026-10-17-search-keys.md).
    module Search
      # The punctuation a phone number is written with, which a word made
      # of nothing else (and at least one digit) is a number spelled.
      PHONE_WORD = /\A[\d().+-]*\d[\d().+-]*\z/ #: Regexp
      private_constant :PHONE_WORD

      # What a word is matched against, already folded: the text fields,
      # each number's digits, and the words of the name and nickname a
      # name hit is read off. Stored per card (Store#reindex); a group's
      # is made at search time, and added to each member's.
      # @rbs skip
      Key = Data.define(:texts, :phones, :names)

      # Reopened rather than defined in the block above, for the reason
      # CardDiff is.
      class Key
        #: (String json) -> Key
        def self.parse(json)
          fields = JSON.parse(json)
          new(texts: fields.fetch("texts"), phones: fields.fetch("phones"), names: fields.fetch("names"))
        end

        #: (*untyped) -> String
        def to_json(*) = JSON.generate({texts:, phones:, names:})

        #: (Key other) -> Key
        def +(other) = with(texts: texts + other.texts, phones: phones + other.phones)
      end

      # A contact's key, off its own card and components alone.
      #: (Contact contact) -> Key
      def self.key(contact)
        Key.new(
          texts: text_fields(contact).map { Format.search_key(it) },
          phones: contact.phones.map { digits(it.value) },
          names: [contact.name, contact.nickname].compact.flat_map { Format.search_key(it).split },
        )
      end

      # The ids of the contacts the query matches, in the order a search
      # is read: a hit on the name first — every word the start of a
      # word of the name or nickname, "ada" or "love" for Ada Lovelace —
      # then the hits anywhere else, recency keeping its order within
      # each. The keys arrive newest first, and partition keeps it.
      #: (Hash[String, Key] keys, query: String, groups: Array[Group]) -> Array[String]
      def self.contacts(keys, query:, groups:)
        words = words(query)
        lent = {} #: Hash[String, Array[Key]]
        groups.each { |group|
          key = group_key(group)
          group.members.each { (lent[it] ||= []) << key }
        }
        matched = keys.select { |id, key| matches?(lent.fetch(id, []).reduce(key) { |all, more| all + more }, words) }
        names, rest = matched.keys.partition { name_hit?(keys.fetch(it), words) }
        names + rest
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

      # What a group lends as a search key: its addresses' and note's
      # text, added to each member's key at search time, and its label.
      # Lent lines hold no name, so a name hit is always the contact's
      # own.
      #: (Group group) -> Key
      def self.group_key(group)
        texts = group.addresses.map { |address|
          Format.search_key(
            [address.extended, address.street, address.locality, address.region, address.postal_code, address.country].compact.join(" ")
          )
        }
        texts << Format.search_key(group.note) if group.note
        Key.new(texts: [*texts, Format.search_key(group.label)], phones: [], names: [])
      end
      private_class_method :group_key

      #: (Key key, Array[String] words) -> bool
      def self.matches?(key, words)
        words.all? { |word|
          key.texts.any? { it.include?(word) } ||
            (word.match?(PHONE_WORD) && key.phones.any? { it.include?(digits(word)) })
        }
      end
      private_class_method :matches?

      # Every value of the contact a word is matched against as text:
      # its names, organization, emails, addresses, and note. An
      # address is its components run together, so "main st" finds a
      # street. The contact is the stored one (Store#reindex's), so its
      # addresses and note are the entity's own; what a group lends is
      # added at search time (#group_key).
      #: (Contact contact) -> Array[String]
      def self.text_fields(contact)
        [
          contact.name,
          contact.nickname,
          contact.organization,
          *contact.emails.map(&:value),
          *contact.addresses.map { [it.extended, it.street, it.locality, it.region, it.postal_code, it.country].compact.join(" ") },
          contact.note,
        ].compact
      end
      private_class_method :text_fields

      #: (Key key, Array[String] words) -> bool
      def self.name_hit?(key, words)
        words.all? { |word| key.names.any? { it.start_with?(word) } }
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
