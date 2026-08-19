require "kdl"
require "pathname"

require "pro_tacts"
require "pro_tacts/vcard"

module ProTacts
  # A contact parsed from one KDL file under the contacts directory; the
  # file is a bare KDL document, and the filename is the id, which maps
  # to the vCard UID (see docs/plans/2026-01-12-carddav-architecture.md).
  class Contact < Data.define(:id, :vcard)
    # Ids end up in paths and arrive from client-supplied hrefs, so a
    # filename outside this charset cannot be served.
    ID_FORMAT = /\A[\w-]+\z/

    # Every contact in the directory, one file per contact. An empty
    # directory is a valid empty address book, and dotfiles are skipped
    # (Finder drops .DS_Store into any directory it opens). Anything
    # else raises: a bad file 500s the request and lands in Sentry
    # rather than quietly serving a partial address book. A missing
    # directory surfaces as Errno::ENOENT from Pathname#children.
    def self.all(directory = ProTacts.config.contacts_dir)
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

      new(id:, vcard: VCard.render(KDL.parse(path.read), uid: id))
    end
  end
end
