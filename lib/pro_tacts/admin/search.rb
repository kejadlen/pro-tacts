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
    # indexed: a family's book is small enough to walk whole, and SQLite
    # FTS5 was weighed and set aside for it (ranger pnrqpyvk).
    module Search
      # The punctuation a phone number is written with, which a word made
      # of nothing else (and at least one digit) is a number spelled.
      PHONE_WORD = /\A[\d().+-]*\d[\d().+-]*\z/ #: Regexp
      private_constant :PHONE_WORD

      # The contacts the query matches, in the order a search is read:
      # a hit on the name first — every word the start of a word of the
      # name or nickname, "ada" or "love" for Ada Lovelace — then the
      # hits anywhere else, recency keeping its order within each. The
      # rows arrive in recency order, and partition keeps it. The groups
      # arrive whole because a contact is found by the names of the
      # groups it is in.
      #: (Array[Store::RecentContact] rows, query: String, groups: Array[Group]) -> Array[Store::RecentContact]
      def self.contacts(rows, query:, groups:)
        words = words(query)
        labels = {} #: Hash[String, Array[String]]
        groups.each { |group| group.members.each { (labels[it] ||= []) << group.label } }
        matched = rows.select { |row| matches?(row.contact, words, labels.fetch(row.contact.id, [])) }
        names, rest = matched.partition { name_hit?(it.contact, words) }
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

      #: (Contact contact, Array[String] words, Array[String] labels) -> bool
      def self.matches?(contact, words, labels)
        texts = text_fields(contact, labels).map { Format.search_key(it) }
        phones = contact.phones.map { digits(it.value) }
        words.all? { |word|
          texts.any? { it.include?(word) } ||
            (word.match?(PHONE_WORD) && phones.any? { it.include?(digits(word)) })
        }
      end
      private_class_method :matches?

      # Every value of the contact a word is matched against as text:
      # its names, emails, addresses, notes, and groups. An address is
      # its components run together, so "main st" finds a street.
      #: (Contact contact, Array[String] labels) -> Array[String]
      def self.text_fields(contact, labels)
        [
          contact.name,
          contact.nickname,
          contact.organization,
          *contact.emails.map(&:value),
          *contact.addresses.map { [it.extended, it.street, it.locality, it.region, it.postal_code, it.country].compact.join(" ") },
          *contact.notes.map(&:value),
          *labels,
        ].compact
      end
      private_class_method :text_fields

      #: (Contact contact, Array[String] words) -> bool
      def self.name_hit?(contact, words)
        name_words = [contact.name, contact.nickname].compact.flat_map { Format.search_key(it).split }
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
