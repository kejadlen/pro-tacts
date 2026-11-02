require "pro_tacts/contact"

module ProTacts
  module Import
    # The contacts already in the book that an arriving card may be
    # the same person as, offered beside that card's editor as the
    # ones it could update instead of arriving new
    # (docs/plans/2026-09-23-merging-on-import.md, "Finding them": edit
    # distance over the name, each email and each phone, offered on
    # the best one field and ranked by the sum).
    module Match
      # How alike two values must be to offer the contact, as the share
      # of the longer one an edit leaves alone: "Jon Smith" and "John
      # Smith" are one edit in ten characters, 0.9.
      THRESHOLD = 0.8 #: Float

      # How many are offered, best first. The toggle above the editor
      # is a row of them, and a row past three is a list to read.
      LIMIT = 3 #: Integer

      # A phone number's national number, near enough everywhere: the
      # digits a country code or a trunk prefix sit in front of. Read
      # from the right, so "+1 555 0100" and "(555) 0100" compare as
      # the same number.
      PHONE_DIGITS = 10 #: Integer

      # The contacts `arriving` might be, most alike first.
      #: (ContactDetails arriving, Array[ListedContact] contacts) -> Array[ListedContact]
      def self.candidates(arriving, contacts)
        scored = contacts.filter_map { |contact|
          fields = likeness(arriving, contact)
          next if (fields.max || 0.0) < THRESHOLD

          pair = [contact, fields.sum(0.0)] #: [ListedContact, Float]
          pair
        }
        scored.sort_by { -it[1] }.first(LIMIT).map { it[0] }
      end

      # How alike the two are in each of the three, from 0 for nothing
      # alike to 1 for a value they share.
      #: (ContactDetails arriving, ListedContact stored) -> Array[Float]
      def self.likeness(arriving, stored)
        [
          closest(names(arriving), names(stored)),
          closest_address(emails(arriving), emails(stored)),
          closest(phones(arriving), phones(stored)),
        ]
      end

      # A phone number as the match compares it, and as the merge asks
      # whether a contact already has it (Import::Merge): its digits,
      # the last PHONE_DIGITS of them.
      #: (String value) -> String
      def self.phone(value)
        value.delete("^0-9").chars.last(PHONE_DIGITS).join
      end

      # Levenshtein's distance: the fewest single-character insertions,
      # deletions and substitutions that turn one string into the
      # other, a row of the table at a time.
      #: (String a, String b) -> Integer
      def self.distance(a, b)
        above = (0..b.length).to_a
        a.each_char.with_index(1) do |x, i|
          row = [i]
          b.each_char.with_index(1) do |y, j|
            substitution = above.fetch(j - 1) + (x == y ? 0 : 1)
            deletion = above.fetch(j) + 1
            insertion = row.fetch(j - 1) + 1
            row << [substitution, deletion, insertion].min.to_i
          end
          above = row
        end
        above.fetch(b.length)
      end

      # The best likeness of any value on one side to any on the other,
      # and none for a side with nothing to compare.
      #: (Array[String] ours, Array[String] theirs) -> Float
      def self.closest(ours, theirs)
        ours.product(theirs).map { |a, b| likeness_of(a, b) }.max || 0.0
      end

      # A value they share is wholly alike, the empty one included: two
      # addresses with nothing before the @ at one domain are one
      # address, not a 0/0.
      #: (String a, String b) -> Float
      def self.likeness_of(a, b)
        return 1.0 if a == b

        1.0 - distance(a, b).fdiv([a.length, b.length].max.to_i)
      end

      # The name as its words, sorted: "Booles, Jane" and "Jane
      # Booles" are one name written two ways, and an edit distance
      # over the two spellings would call them strangers.
      #: (ContactDetails | ListedContact contact) -> Array[String]
      def self.names(contact)
        [contact.name.to_s.downcase.scan(/[[:alnum:]]+/).sort.join(" ")].reject(&:empty?)
      end

      # An address's case is no part of it.
      #: (ContactDetails | ListedContact contact) -> Array[String]
      def self.emails(contact)
        contact.emails.map { it.value.strip.downcase }.reject(&:empty?)
      end

      # Two addresses as alike as the parts before their @, at one
      # domain, and not alike at all at two (the plan's "Finding
      # them").
      #: (Array[String] ours, Array[String] theirs) -> Float
      def self.closest_address(ours, theirs)
        ours.product(theirs).map { |a, b|
          local, _, domain = a.rpartition("@")
          other, _, other_domain = b.rpartition("@")
          domain == other_domain ? likeness_of(local, other) : 0.0
        }.max || 0.0
      end

      #: (ContactDetails | ListedContact contact) -> Array[String]
      def self.phones(contact)
        contact.phones.map { phone(it.value) }.reject(&:empty?)
      end

      private_class_method :closest, :closest_address, :likeness_of, :names, :emails, :phones
    end
  end
end
