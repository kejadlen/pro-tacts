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
    # as. REVISED is the cards as they will be written — pared to what
    # this book reads when the import opens (Vcf.read), and rewritten
    # whole each time the editor saves one of them. SAVED is what the
    # import has already done: the group it files its arrivals under,
    # and which of its cards are contacts now.
    #
    # That last one is what makes the walk resumable rather than
    # batched. A card is written the moment its Save is pressed
    # (Import::Write), so the store is the record of it and this slot
    # is only how the list knows which rows are done. Nothing here
    # holds a decision back: the groups a contact joins are ticked and
    # written by that same Save, so they are never staged at all.
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
      REVISED = "revised" #: String
      SAVED = "saved" #: String
      SLOTS = [ORIGINAL, REVISED, SAVED].freeze #: Array[String]

      # The two halves of the saved slot: the name of the group this
      # import files its arrivals under, and the contact each saved
      # card became, by the card's place in the file.
      GROUP = "group" #: String
      CONTACTS = "contacts" #: String

      # How long an import is worth keeping. Long enough to work down
      # a book's worth of contacts over an evening, and short enough
      # that a window closed on the review screen does not leave that
      # book on disk for a week.
      LIFETIME = 86_400 #: Integer

      # A new import, under a fresh id, which is what every screen of
      # it carries. Minted, so the id a link or a form hands back is
      # checked against the one shape this writes (#path) rather than
      # trusted as a filename.
      #: (original: String, revised: String, group: String) -> String
      def self.open(original:, revised:, group:)
        sweep
        id = ChangeId.mint(ChangeId::CONTACT_LENGTH)
        directory = root / id
        FileUtils.mkdir_p(directory)
        File.binwrite(directory / file_name(ORIGINAL), original)
        File.binwrite(directory / file_name(REVISED), revised)
        # The group is settled here rather than at the end, there
        # being no end to settle it at any more: every Save files its
        # contact under it, and nothing renames it afterwards — a
        # rename would leave what is already in the book under the old
        # name and put the rest somewhere else. Nothing saved yet, and
        # empty rather than absent, so every slot of an import that
        # exists is a file that exists and a write can say which of
        # the two it found (#write).
        none = {} #: Hash[String, String]
        File.binwrite(directory / file_name(SAVED), JSON.generate({GROUP => group, CONTACTS => none}))
        id
      end

      # One slot's bytes, or none — an import swept out from under a
      # screen left open overnight, or one already closed by the Save
      # that took its last card in. Ordinary enough for the screen to
      # say so and ask for the file again.
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

      # The cards as they will be written, rewritten: the editor's
      # save, and one of the two writes this takes after the import
      # opens. Whole rather than a card at a time, because the file is
      # the unit a re-read splits (Vcf.cards) and a card's index in it
      # is how a screen names one.
      #
      # Still rewritten for a card that was just saved into the store,
      # rather than dropped from the file: the walk's list renders
      # every row from these bytes, and a row that has come in is one
      # it still has to be able to name (Admin::ImportSidebar).
      #: (String id, String revised) -> void
      def self.update(id, revised)
        write(id, REVISED, revised)
      end

      # What this import has done: the group it files under, and the
      # contact each saved card became, by the card's place in the
      # file — the name every screen of the walk calls a contact by
      # until there is a minted id to call it by instead. Two empty
      # answers for an import that is gone or a slot that will not
      # parse: this is a file on disk, and one that will not read back
      # in the shape it was written in is a broken assumption JSON
      # says so about.
      #: (String id) -> [String, Hash[String, String]]
      def self.saved(id)
        raw = read(id, SAVED)
        return ["", ids(nil)] if raw.nil?

        parsed = JSON.parse(raw)
        return ["", ids(nil)] unless parsed.is_a?(Hash)

        [parsed[GROUP].to_s, ids(parsed[CONTACTS])]
      end

      # One card, written: its place in the file against the id the
      # store minted for it. Read back and rewritten whole, the slot
      # beside this one being written the same way.
      #: (String id, String index, String contact) -> void
      def self.record(id, index, contact)
        group, contacts = saved(id)
        write(id, SAVED, JSON.generate({GROUP => group, CONTACTS => contacts.merge(index => contact)}))
      end

      # The import, gone: what the walk's last screen leaves behind,
      # and what keeps the ordinary case from waiting on the sweep.
      # The contacts it wrote are in the store and stay there; this
      # takes only the file and the walk's own notes.
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

      # One map of a contact's place in the file to the id it was
      # stored under, out of whatever the file actually holds.
      #: (untyped raw) -> Hash[String, String]
      def self.ids(raw)
        ids = {} #: Hash[String, String]
        return ids unless raw.is_a?(Hash)

        raw.each { |index, contact| ids[index.to_s] = contact.to_s }
        ids
      end

      # The cards are a .vcf, and the walk's notes beside them are not.
      #: (String slot) -> String
      def self.file_name(slot)
        slot == ORIGINAL || slot == REVISED ? "#{slot}.vcf" : "#{slot}.json"
      end

      private_class_method :root, :import_root, :path, :file_name, :write, :ids
    end
  end
end
