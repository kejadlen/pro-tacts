require "securerandom"

module ProTacts
  # Ids in the shape jj spells a change id: letters from k to z, so an id
  # is never a hash and never a word its author meant. Minted rather
  # than chosen, which is what lets a person read one
  # (db/migrations/005_group_identity.rb).
  module ChangeId
    ALPHABET = "klmnopqrstuvwxyz".chars.freeze #: Array[String]

    # SecureRandom rather than rand: the draws have to be independent of
    # anything a caller can observe or seed.
    #: (Integer length) -> String
    def self.mint(length)
      SecureRandom.alphanumeric(length, chars: ALPHABET)
    end
  end
end
