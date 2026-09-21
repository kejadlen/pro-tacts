require "fileutils"
require "json"
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
    # Three slots per import. ORIGINAL is the uploaded file, written
    # once and never again: it is what the left-hand card renders, and
    # a card that has been edited still has to show what it arrived
    # as. LANDING is the cards as they will land — pared to what this
    # book reads when the import opens (Vcf.read), and rewritten whole
    # each time the editor saves one of them. GROUPS is which groups
    # each of those cards is joining, a decision the cards themselves
    # cannot carry: a vCard says nothing about this book's groups, and
    # a line invented to hold the answer would land in the contact.
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
      GROUPS = "groups" #: String
      SLOTS = [ORIGINAL, LANDING, GROUPS].freeze #: Array[String]

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
        # Empty rather than absent, so every slot of an import that
        # exists is a file that exists and a write can say which of
        # the two it found (#write).
        File.binwrite(directory / file_name(GROUPS), JSON.generate({}))
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
        write(id, LANDING, landing)
      end

      # Which groups each contact joins, by its place in the file —
      # the name every screen of the walk calls a contact by, there
      # being no minted id until it lands. Rewritten whole like the
      # cards beside it, and for the same reason: one save is one
      # state of the whole import.
      #: (String id, Hash[String, Array[String]] groups) -> void
      def self.update_groups(id, groups)
        write(id, GROUPS, JSON.generate(groups))
      end

      # What #update_groups last wrote, and nothing for an import
      # that is gone. Read back into the shape it was written in
      # rather than trusted: this is a file on disk, and a slot that
      # will not parse is a broken assumption JSON says so about.
      #: (String id) -> Hash[String, Array[String]]
      def self.groups(id)
        raw = read(id, GROUPS)
        return {} if raw.nil?

        parsed = JSON.parse(raw)
        return {} unless parsed.is_a?(Hash)

        parsed.to_h { |index, ids| [index.to_s, (ids.is_a?(Array) ? ids : []).map(&:to_s)] }
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

      # One slot, rewritten. Both refusals name which of the two
      # things went wrong: an id this never minted, or an import that
      # is no longer here.
      #: (String id, String slot, String contents) -> void
      def self.write(id, slot, contents)
        file = path(id, slot) or raise ArgumentError, "#{id} is not an import id"
        raise ArgumentError, "#{id} is not an import in progress" unless file.file?

        File.binwrite(file.to_s, contents)
      end

      # The cards are a .vcf, and the groups beside them are not.
      #: (String slot) -> String
      def self.file_name(slot)
        slot == GROUPS ? "#{slot}.json" : "#{slot}.vcf"
      end

      private_class_method :root, :import_root, :path, :file_name, :write
    end
  end
end
