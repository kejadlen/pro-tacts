require "fileutils"
require "pathname"

require "pro_tacts"
require "pro_tacts/change_id"

module ProTacts
  module Import
    # An import in progress, on disk between the requests that make it
    # up (docs/plans/2026-09-21-import-a-vcf.md). A review is a walk
    # over the contacts in a file, a screen at a time, and what the
    # walk is reading and writing has to outlive each request.
    #
    # Two slots per import, because the review screen shows two things
    # at once. ORIGINAL is the uploaded file, written once and never
    # again: it is what the left-hand card renders, and a card that has
    # been edited still has to show what it arrived as. LANDING is the
    # cards as they will land — pared to what this book reads when the
    # import opens (Vcf.read), and rewritten whole each time the editor
    # saves one of them.
    #
    # On disk rather than in the browser: a book with pictures in it is
    # tens of megabytes, and a form carrying it back and forth is the
    # upload done once per screen. Under the data directory, which is
    # the one place this app writes (Config#data_dir), and not the
    # system temp dir: a half-finished import is this server's own
    # state, short-lived without being anyone else's.
    module Staged
      # Where they wait, a directory per import. Beside the database
      # rather than in it: these are not cards yet, and nothing reads
      # them but the screens of the import that wrote them.
      DIRECTORY = "imports" #: String

      ORIGINAL = "original" #: String
      LANDING = "landing" #: String
      SLOTS = [ORIGINAL, LANDING].freeze #: Array[String]

      # How long an import is worth keeping. Long enough to work down
      # a book's worth of contacts over an evening, and short enough
      # that a window closed on the review screen does not leave that
      # book on disk for a week.
      LIFETIME = 86_400 #: Integer

      # A new import, under a fresh id, which is what every screen of
      # it carries. Minted, so the id a link or a form hands back is
      # checked against the one shape this writes (#path) rather than
      # trusted as a filename.
      #: (original: String, landing: String) -> String
      def self.open(original:, landing:)
        sweep
        id = ChangeId.mint(ChangeId::CONTACT_LENGTH)
        directory = root / id
        FileUtils.mkdir_p(directory)
        File.binwrite(directory / file_name(ORIGINAL), original)
        File.binwrite(directory / file_name(LANDING), landing)
        id
      end

      # One slot's bytes, or none — an import swept out from under a
      # screen left open overnight, or one already landed, its second
      # confirm finding what the first removed. Ordinary enough for
      # the screen to say so and ask for the file again.
      #: (String id, String slot) -> String?
      def self.read(id, slot)
        file = path(id, slot)
        return nil if file.nil? || !file.file?

        # UTF-8 because nothing is written here that the route has not
        # already judged to be text (Web#stage_upload, Web#write_card's
        # rule); a card refuses to be made of anything else regardless
        # (VCard#initialize).
        File.read(file.to_s, encoding: Encoding::UTF_8)
      end

      # The cards as they will land, rewritten: the editor's save, and
      # the only write this takes after the import opens. Whole rather
      # than a card at a time, because the file is the unit a re-read
      # splits (Vcf.cards) and a card's index in it is how a screen
      # names one.
      #: (String id, String landing) -> void
      def self.update(id, landing)
        file = path(id, LANDING) or raise ArgumentError, "#{id} is not an import id"
        raise ArgumentError, "#{id} is not an import in progress" unless file.file?

        File.binwrite(file.to_s, landing)
      end

      # The import, gone: the last step of a landing, and what keeps
      # the ordinary case from waiting on the sweep.
      #: (String id) -> void
      def self.close(id)
        directory = import_root(id)
        FileUtils.rm_rf(directory.to_s) if directory
      end

      # Every import past its LIFETIME, gone. Run on the way in rather
      # than on a timer, because an upload is the only thing that
      # opens one and a directory nobody is adding to is not growing.
      #: (?now: Time) -> void
      def self.sweep(now: Time.now)
        directory = root
        return unless directory.directory?

        directory.each_child do |import|
          FileUtils.rm_rf(import.to_s) if now - import.mtime > LIFETIME
        end
      end

      #: () -> Pathname
      def self.root
        ProTacts.config.data_dir / DIRECTORY
      end

      # The directory an id names, or none for an id this never wrote.
      # The check is the whole of the path safety here: an id comes
      # back off a link or a form, and `../../contacts.db` is a
      # filename too.
      #: (String id) -> Pathname?
      def self.import_root(id)
        return nil unless ChangeId.minted?(id)

        root / id
      end

      # One slot's file. The slot is checked as narrowly as the id,
      # for the reason the id is.
      #: (String id, String slot) -> Pathname?
      def self.path(id, slot)
        directory = import_root(id)
        return nil if directory.nil? || !SLOTS.include?(slot)

        directory / file_name(slot)
      end

      #: (String slot) -> String
      def self.file_name(slot)
        "#{slot}.vcf"
      end

      private_class_method :root, :import_root, :path, :file_name
    end
  end
end
