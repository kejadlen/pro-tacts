require "digest"

module ProTacts
  # A sync token as this server spells one: the ctag it was minted at
  # and the book it was minted for, in a URI. Opaque to the client
  # (RFC 6578 section 3) and the URI form is conventional, but not
  # opaque to this server, which has to tell its own token from one
  # another book minted — the one a rename leaves a user holding
  # included (docs/plans/2026-09-12-per-user-books.md, "The wire").
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

    #: (String ctag, String book) -> String
    def self.mint(ctag, book)
      "#{PREFIX}#{ctag}/#{book}"
    end

    # The sequence a token carries, or nil for one this book did not
    # mint — another book's, a rename's leftover, or a string that is
    # no token of ours at all. Whether the sequence is one the change
    # log can still answer from is the caller's to judge.
    #: (String token, String book) -> Integer?
    def self.read(token, book)
      token[%r{\A#{Regexp.escape(PREFIX)}(\d+)/#{Regexp.escape(book)}\z}, 1]&.to_i
    end
  end
end
