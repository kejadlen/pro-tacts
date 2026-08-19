require "kdl"
require "pathname"
require "sentry-ruby"

require "pro_tacts/vcard"

module ProTacts
  # Reads contacts from a directory of KDL files, one contact per file.
  # The filename minus extension is the contact ID, which maps to the
  # vCard UID (see docs/plans/2026-01-12-carddav-architecture.md).
  class Contacts
    Contact = Struct.new(:id, :vcard, keyword_init: true)

    # IDs end up in paths, and they arrive from client-supplied hrefs, so
    # anything outside this charset simply does not exist.
    ID_FORMAT = /\A[\w-]+\z/

    attr_reader :directory

    def initialize(directory)
      @directory = Pathname.new(directory)
      unless @directory.directory?
        raise ArgumentError, "contacts directory not found: #{@directory}"
      end
    end

    def all
      directory.glob("*.kdl").sort.map { load(it) }.compact
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
