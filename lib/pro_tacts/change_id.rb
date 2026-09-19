require "securerandom"

module ProTacts
  # Ids in the shape jj spells a change id: letters from k to z, so an id
  # is never a hash and never a word its author meant. Minted rather
  # than chosen, which is what lets a person read one
  # (db/migrations/005_group_identity.rb).
  module ChangeId
    ALPHABET = "klmnopqrstuvwxyz".chars.freeze #: Array[String]

    # The length a contact's id is minted at. Store#put overwrites
    # rather than refuses, so the width is the only guard a create has:
    # 48 bits, for a family's book. The admin create draws it (Web's
    # contacts branch); Store#reid measures ids against it.
    CONTACT_LENGTH = 12 #: Integer

    # SecureRandom rather than rand: the draws have to be independent of
    # anything a caller can observe or seed.
    #: (Integer length) -> String
    def self.mint(length)
      SecureRandom.alphanumeric(length, chars: ALPHABET)
    end

    # Whether an id is one this server minted for a contact: the shape
    # #mint draws at CONTACT_LENGTH, and nothing else. Ids that fail
    # this — a client's UUID, a seed from before the shape settled —
    # are what rake contacts:reid moves.
    #: (String id) -> bool
    def self.minted?(id)
      /\A[#{ALPHABET.join}]{#{CONTACT_LENGTH}}\z/.match?(id)
    end
  end
end
