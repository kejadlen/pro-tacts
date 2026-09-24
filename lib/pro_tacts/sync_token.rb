require "digest"

module ProTacts
  # A sync token as this server spells one: the ctag it was minted at,
  # the book it was minted for, and the database that minted it, in a
  # URI. Opaque to the client (RFC 6578 section 3) and the URI form is
  # conventional, but not opaque to this server, which has to tell its
  # own token from one another book minted — the one a rename leaves a
  # user holding included (docs/plans/2026-09-12-per-user-books.md,
  # "The wire") — and from one another database minted: a reseed or a
  # dump restored repeats the sequences, and the id is what refuses
  # that token rather than answering a delta against a history it
  # never saw
  # (docs/plans/2026-09-24-sync-tokens-name-their-database.md).
  # Built on the ctag so that a client polling either one sees changes
  # at the same points.
  module SyncToken
    PREFIX = "http://pro-tacts/sync/" #: String

    # The book half: the first 16 hex digits of the SHA-256 of the
    # requester's login.
    #: (String login) -> String
    def self.book(login)
      Digest::SHA256.hexdigest(login)[0, 16].to_s
    end

    #: (String ctag, String book, String database_id) -> String
    def self.mint(ctag, book, database_id)
      "#{PREFIX}#{ctag}/#{book}/#{database_id}"
    end

    # The sequence a token carries, or nil for one this database did
    # not mint — another database's (a reseed's, a restore's), another
    # book's, a rename's leftover, or a string that is no token of
    # ours at all. Whether the sequence is one the change log can
    # still answer from is the caller's to judge.
    #: (String token, String book, String database_id) -> Integer?
    def self.read(token, book, database_id)
      token[%r{\A#{Regexp.escape(PREFIX)}(\d+)/#{Regexp.escape(book)}/#{Regexp.escape(database_id)}\z}, 1]&.to_i
    end
  end
end
