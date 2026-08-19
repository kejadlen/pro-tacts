require "kdl"
require "pathname"
require "sentry-ruby"

require "pro_tacts/vcard"

module ProTacts
  # Reads contacts from a directory of KDL files, one contact per file.
  # The filename minus extension is the contact ID, which maps to the
  # vCard UID (see docs/plans/2026-01-12-carddav-architecture.md).
  class Contacts
    Contact = Data.define(:id, :vcard)

    # IDs end up in paths, and they arrive from client-supplied hrefs, so
    # anything outside this charset simply does not exist. Enforced at
    # load too, so everything listed is fetchable by that id.
    ID_FORMAT = /\A[\w-]+\z/

    attr_reader :directory

    def initialize(directory)
      @directory = Pathname.new(directory)
      unless @directory.directory?
        raise ArgumentError, "contacts directory not found: #{@directory}"
      end
    end

    # An empty directory is a valid empty address book. Anything in it
    # that is not a .kdl file means a misplaced file or a wrong
    # PRO_TACTS_CONTACTS_DIR, so it raises rather than quietly serving a
    # partial address book. Dotfiles are exempt: Finder drops .DS_Store
    # into any directory it opens.
    def all
      unexpected = directory.children
        .reject { it.basename.to_s.start_with?(".") }
        .reject { it.extname == ".kdl" }
      unless unexpected.empty?
        raise ArgumentError, "unexpected non-KDL file in contacts directory: #{unexpected.first}"
      end

      directory.glob("*.kdl").map { load(it) }.compact
    end

    def find(id)
      return nil unless id.match?(ID_FORMAT)

      path = directory / "#{id}.kdl"
      load(path) if path.file?
    end

    private

    # Rendering at load time doubles as validation: a file whose card
    # cannot render is reported and skipped rather than taking the whole
    # address book down with it. Sentry is a no-op while uninitialized,
    # so tests need no DSN.
    def load(path)
      id = path.basename(".kdl").to_s
      unless id.match?(ID_FORMAT)
        raise ArgumentError, "invalid contact id: #{id}"
      end

      nodes = KDL.parse(path.read).nodes
      unless nodes.length == 1 && nodes.first.name == "contact"
        raise ArgumentError, "expected exactly one contact node"
      end

      Contact.new(id:, vcard: VCard.render(nodes.first, uid: id))
    rescue KDL::Error, ArgumentError, SystemCallError => e
      Sentry.capture_message("skipping contact file #{path}: #{e.class}: #{e.message}")
      nil
    end
  end
end
