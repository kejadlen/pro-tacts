require "fileutils"
require "pathname"

require "pro_tacts"
require "pro_tacts/change_id"

module ProTacts
  module Import
    # The uploaded file, held between the two halves of an import
    # (docs/plans/2026-09-21-import-a-vcf.md). The screen cannot ask
    # what to do with a property until it has read the file, and the
    # answer comes back in a second request — so the bytes wait here
    # rather than riding out to the browser and back in a hidden
    # field, which would carry a book's pictures twice over.
    #
    # Under the data directory, which is the one place this app writes
    # (Config#data_dir), and not the system temp dir: a half-finished
    # import is this server's own state, short-lived without being
    # anyone else's.
    module Staged
      # Where they wait. Beside the database rather than under it: a
      # file here is not a card yet and nothing reads it but the
      # request that lands it.
      DIRECTORY = "imports" #: String

      # How long an upload is worth keeping. Long enough to read a
      # list of properties and think about it, short enough that a
      # window closed on the review screen does not leave a book on
      # disk for a week.
      LIFETIME = 3600 #: Integer

      # The bytes staged under a fresh id, which is what the review
      # screen carries so the confirm can find them again. Minted, so
      # the id a form hands back is checked against the one shape this
      # writes (#path) rather than trusted as a filename.
      #: (String bytes) -> String
      def self.write(bytes)
        directory = root
        FileUtils.mkdir_p(directory)
        sweep
        id = ChangeId.mint(ChangeId::CONTACT_LENGTH)
        File.binwrite(directory / file_name(id), bytes)
        id
      end

      # The staged bytes, or none — an upload swept out from under a
      # review screen left open, or a confirm submitted twice, the
      # second finding what the first removed. Ordinary enough for the
      # screen to say so and ask for the file again.
      #: (String id) -> String?
      def self.read(id)
        file = path(id)
        return nil if file.nil? || !file.file?

        # UTF-8 because #write is only ever handed bytes the route has
        # already judged to be text (Web#survey_upload, Web#write_card's
        # rule); a card refuses to be made of anything else regardless
        # (VCard#initialize).
        File.read(file, encoding: Encoding::UTF_8)
      end

      # The staged file, gone: the last step of a landing, and what
      # keeps the ordinary case from waiting on the sweep.
      #: (String id) -> void
      def self.remove(id)
        file = path(id)
        FileUtils.rm_f(file) if file
      end

      # Every upload past its LIFETIME, gone. Run on the way in rather
      # than on a timer, because an import is the only thing that
      # writes here and a directory nobody is adding to is not growing.
      #: (?now: Time) -> void
      def self.sweep(now: Time.now)
        directory = root
        return unless directory.directory?

        directory.each_child do |path|
          FileUtils.rm_f(path) if path.file? && now - path.mtime > LIFETIME
        end
      end

      #: () -> Pathname
      def self.root
        ProTacts.config.data_dir / DIRECTORY
      end

      # The file an id names, or none for an id this never wrote. The
      # check is the whole of the path safety here: an id comes back
      # off a form, and `../../contacts.db` is a filename too.
      #: (String id) -> Pathname?
      def self.path(id)
        return nil unless ChangeId.minted?(id)

        root / file_name(id)
      end

      #: (String id) -> String
      def self.file_name(id)
        "#{id}.vcf"
      end

      private_class_method :root, :path, :file_name
    end
  end
end
