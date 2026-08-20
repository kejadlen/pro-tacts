require "digest"
require "kdl"
require "pathname"

require "pro_tacts/vcard"

module ProTacts
  # A contact parsed from one KDL file under the contacts directory; the
  # file is a bare KDL document, and the filename is the id, which maps
  # to the vCard UID (see docs/plans/2026-01-12-carddav-architecture.md).
  #
  # The etag hashes the rendered vCard rather than the file's bytes or
  # mtime, so it changes exactly when what the client downloads changes:
  # git rewrites mtimes on every checkout, and a reformat-only edit
  # changes the bytes without changing the card. It is stored in the
  # entity-tag's quoted form (RFC 7232 section 2.3), which is what both
  # the ETag header and getetag properties carry.
  #
  # The signature lives in sig/pro_tacts/contact.rbs: a Data class has
  # no constant super class for the inline syntax to read.
  # @rbs skip
  class Contact < Data.define(:id, :vcard, :etag)
    # Ids end up in paths and arrive from client-supplied hrefs, so a
    # filename outside this charset cannot be served.
    ID_FORMAT = /\A[\w-]+\z/

    # Every contact in the directory, one file per contact. An empty
    # directory is a valid empty address book, and dotfiles are skipped
    # (Finder drops .DS_Store into any directory it opens). Anything
    # else raises: a bad file 500s the request and lands in Sentry
    # rather than quietly serving a partial address book. A missing
    # directory surfaces as Errno::ENOENT from Pathname#children.
    def self.all(directory)
      Pathname.new(directory).children
        .reject { it.basename.to_s.start_with?(".") }
        .map { parse(it) }
    end

    # File to Contact; raises on any filename or content that would make
    # the contact unloadable.
    def self.parse(path)
      path = Pathname.new(path)
      id = path.basename(".kdl").to_s
      raise ArgumentError, "invalid contact id: #{id}" unless id.match?(ID_FORMAT)

      vcard = VCard.render(KDL.parse(path.read), uid: id)
      new(id:, vcard:, etag: %("#{Digest::SHA256.hexdigest(vcard)}"))
    end
  end
end
