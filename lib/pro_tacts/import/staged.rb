require "fileutils"
require "json"
require "pathname"

require "pro_tacts"
require "pro_tacts/change_id"

module ProTacts
  module Import
    # An import in progress, on disk between the requests that make it
    # up: why on disk is docs/plans/2026-09-21-import-a-vcf.md, "The
    # import waits on the server", and why a file per card with the
    # list's rows beside them is
    # docs/plans/2026-10-14-lists-read-the-index.md, "The import".
    # Under the data directory, which is the one place this app writes
    # (Config#data_dir), and not the system temp dir: a
    # half-finished import is this server's own state, short-lived
    # without being anyone else's.
    module Staged
      # Where they wait, a directory per import. Beside the database
      # rather than in it: these are not cards yet, and nothing reads
      # them but the screens of the import that wrote them.
      DIRECTORY = "imports" #: String

      ORIGINAL = "original" #: String
      REVISED = "revised" #: String
      SAVED = "saved" #: String
      ROWS = "rows" #: String
      # The walk's notes, a JSON file each.
      SLOTS = [SAVED, ROWS].freeze #: Array[String]

      # The cards' two slots, each a directory holding a file per card
      # named by its place in the file, so a screen reads the one card
      # it shows rather than every card the upload held.
      CARDS = [ORIGINAL, REVISED].freeze #: Array[String]

      # One row of the walk's list as it was last read: what the row is
      # called and sorted by, off the card as it will be written, and
      # how many of its original's lines are not coming with it
      # (Web#walk_sidebar). Read once at the upload and again for the
      # one card a Save rewrites, rather than off every card on every
      # screen.
      # @rbs skip
      Row = Data.define(:label, :sort_key, :losses)

      # The two halves of the saved slot: the name of the group this
      # import files its arrivals under, and the contact each saved
      # card became, by the card's place in the file.
      GROUP = "group" #: String
      CONTACTS = "contacts" #: String

      # How long an import is worth keeping: an evening's walk, and no
      # longer (the plan's "The import waits on the server").
      LIFETIME = 86_400 #: Integer

      # A new import, under a fresh id, which is what every screen of
      # it carries. Minted, so the id a link or a form hands back is
      # checked against the one shape this writes (#path) rather than
      # trusted as a filename.
      #: (originals: Array[String], revised: Array[String], rows: Array[Row], group: String) -> String
      def self.open(originals:, revised:, rows:, group:)
        sweep
        id = ChangeId.mint(ChangeId::CONTACT_LENGTH)
        directory = root / id
        {ORIGINAL => originals, REVISED => revised}.each do |slot, cards|
          FileUtils.mkdir_p(directory / slot)
          cards.each_with_index { |bytes, index| File.binwrite(directory / slot / "#{index}.vcf", bytes) }
        end
        File.binwrite(directory / file_name(ROWS), JSON.generate(rows.map(&:to_h)))
        # The group is settled here, and never renamed (the plan's
        # "Nothing waits for the end"). Nothing saved yet, and
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

      # One card's bytes from either cards slot, by its place in the
      # file, or none for an import that is gone or a place past its
      # last card.
      #: (String id, String slot, Integer index) -> String?
      def self.card(id, slot, index)
        file = card_path(id, slot, index)
        return nil if file.nil? || !file.file?

        # #read's encoding, for #read's reason.
        File.read(file.to_s, encoding: Encoding::UTF_8)
      end

      # The walk's list, a Row per card in file order, or none for an
      # import that is gone. A slot that will not read back as rows is
      # #saved's broken assumption, and JSON or Row says so.
      #: (String id) -> Array[Row]?
      def self.rows(id)
        raw = read(id, ROWS)
        return nil if raw.nil?

        parsed = JSON.parse(raw, symbolize_names: true) #: Array[Hash[Symbol, untyped]]
        parsed.map { Row.new(label: it.fetch(:label), sort_key: it.fetch(:sort_key), losses: it.fetch(:losses)) }
      end

      # One card as it will be written, rewritten, with its row: the
      # editor's save, and one of the writes this takes after the
      # import opens. Still rewritten for a card that was just saved
      # into the store, rather than dropped: the walk's list names
      # every row, and a row that has come in is one it still has to
      # be able to name (Admin::ImportSidebar).
      #: (String id, Integer index, String bytes, Row row) -> void
      def self.update(id, index, bytes, row)
        file = card_path(id, REVISED, index) or raise ArgumentError, "#{id} is not an import id"
        raise ArgumentError, "#{id} has no card #{index}" unless file.file?

        File.binwrite(file.to_s, bytes)
        rows = rows(id) or raise ArgumentError, "#{id} is not an import in progress"
        rows[index] = row
        write(id, ROWS, JSON.generate(rows.map(&:to_h)))
      end

      # What this import has done: the group it files under, and the
      # contact each saved card became, by the card's place in the
      # file — the name every screen of the walk calls a contact by
      # until there is a minted id to call it by instead. Empty for an
      # import that is gone, #read's ordinary case. A slot that will
      # not read back in the shape #open wrote it in raises, #rows'
      # posture: answering "nothing saved" would send every row back
      # through a Save that writes its contact a second time.
      #: (String id) -> [String, Hash[String, String]]
      def self.saved(id)
        raw = read(id, SAVED)
        return ["", ids({})] if raw.nil?

        parsed = JSON.parse(raw)
        raise ArgumentError, "#{id}'s saved slot is not an object" unless parsed.is_a?(Hash)

        [parsed.fetch(GROUP).to_s, ids(parsed.fetch(CONTACTS))]
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

      # One card's file in a cards slot, checked as #path checks: the
      # place is an Integer the route matched, and never below zero.
      #: (String id, String slot, Integer index) -> Pathname?
      def self.card_path(id, slot, index)
        directory = import_root(id)
        return nil if directory.nil? || !CARDS.include?(slot) || index.negative?

        directory / slot / "#{index}.vcf"
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
      # stored under, refused where the slot holds anything else
      # (#saved's reason).
      #: (untyped raw) -> Hash[String, String]
      def self.ids(raw)
        raise ArgumentError, "the saved slot's contacts are not an object" unless raw.is_a?(Hash)

        ids = {} #: Hash[String, String]
        raw.each { |index, contact| ids[index.to_s] = contact.to_s }
        ids
      end

      #: (String slot) -> String
      def self.file_name(slot)
        "#{slot}.json"
      end

      private_class_method :root, :import_root, :path, :card_path, :file_name, :write, :ids
    end
  end
end
