require "kdl"
require "pathname"
require "sentry-ruby"

require "pro_tacts"
require "pro_tacts/vcard"

module ProTacts
  # A contact parsed from one KDL file under the contacts directory; the
  # file is a bare KDL document, and the filename is the id, which maps
  # to the vCard UID (see docs/plans/2026-01-12-carddav-architecture.md).
  class Contact < Data.define(:id, :vcard)
    # Ids end up in paths and arrive from client-supplied hrefs, so a
    # filename outside this charset is skipped at load; everything
    # listed is then fetchable by its id.
    ID_FORMAT = /\A[\w-]+\z/

    # Every contact in the directory, one file per contact. An empty
    # directory is a valid empty address book, but any non-hidden
    # non-.kdl file raises — a misplaced file or a wrong
    # PRO_TACTS_CONTACTS_DIR should not quietly serve a partial address
    # book. Files that fail to parse or render are reported and skipped;
    # Sentry is a no-op while uninitialized, so tests need no DSN.
    def self.all(directory = ProTacts.config.contacts_dir)
      directory = Pathname.new(directory)
      raise ArgumentError, "contacts directory not found: #{directory}" unless directory.directory?

      unexpected = directory.children
        .reject { it.basename.to_s.start_with?(".") }
        .reject { it.extname == ".kdl" }
      unless unexpected.empty?
        raise ArgumentError, "unexpected non-KDL file in contacts directory: #{unexpected.first}"
      end

      directory.glob("*.kdl").filter_map do |path|
        parse(path)
      rescue KDL::Error, ArgumentError, SystemCallError => e
        Sentry.capture_message("skipping contact file #{path}: #{e.class}: #{e.message}")
      end
    end

    # File to Contact; raises on anything that would make the contact
    # unloadable. `all` decides what to do about it.
    def self.parse(path)
      path = Pathname.new(path)
      id = path.basename(".kdl").to_s
      unless id.match?(ID_FORMAT)
        raise ArgumentError, "invalid contact id: #{id}"
      end

      new(id:, vcard: VCard.render(KDL.parse(path.read), uid: id))
    end
  end
end
