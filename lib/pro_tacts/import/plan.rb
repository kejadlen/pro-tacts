require "fileutils"
require "pathname"
require "time"
require "yaml"

require "pro_tacts/import/card"

module ProTacts
  module Import
    # One import, as a directory: what a source builder decided, and how
    # far execute and clear have carried it
    # (docs/plans/2026-09-16-importing-from-macos.md).
    class Plan
      # @rbs @dir: Pathname
      # @rbs @manifest: Hash[String, untyped]

      # What a builder hands over for one contact: its card, which the
      # plan's own groups are added to. The original rides inside the
      # card (Card::SOURCE_KEYS). Signed in sig/pro_tacts/import.rbs,
      # being a Data class.
      # @rbs skip
      Entry = Data.define(:id, :source_id, :card)

      # A contact as the plan lists it, with the last step it reached:
      # nil, then landed, imported, and cleared, in that order. The name is
      # the card's when the plan was built, written down so a person
      # reading plan.yml can tell which line is whose without opening a
      # card; nothing reads it back to decide anything.
      # @rbs skip
      Contact = Data.define(:id, :source_id, :name, :status)

      FORMAT = 2 #: Integer

      # Store::EVERYONE, spelled out so a plan loads no database.
      EVERYONE = "sync:*" #: String

      # A contact's final state: on the host, in its groups, and off
      # this Mac. A plan whose every contact has reached it is done and
      # files away under done/ (tasks/import.rake).
      CLEARED = "cleared" #: String

      # The spelling of CLEARED plans recorded before the state was
      # named for what it is; read as it so a plan built then files
      # away now.
      REMOVED = "removed" #: String

      # Whether the plan has carried every contact through: nothing
      # left for execute or clear to do.
      #: () -> bool
      def done?
        contacts.all? { [CLEARED, REMOVED].include?(it.status) }
      end

      #: (Pathname dir, source: String, created_at: Time, entries: Array[Entry]) -> Plan
      def self.write(dir, source:, created_at:, entries:)
        FileUtils.mkdir_p(dir.dirname)
        # Raises when the directory is there, so no plan is written over
        # another.
        Dir.mkdir(dir)

        group = "import-#{created_at.utc.strftime("%Y%m%dT%H%M%SZ")}"
        (dir / "cards").mkpath
        entries.each do |entry|
          card = entry.card
          card = card.with(groups: [EVERYONE, group, *card.groups])
          (dir / "cards/#{entry.id}.yml").write(YAML.dump(card.document))
        end

        plan = new(dir, {
          "format" => FORMAT,
          "source" => source,
          "created_at" => created_at.utc.iso8601,
          "group" => group,
          "host" => nil,
          "contacts" => entries.map {
            # A card may hold only one of the two names.
            person = [it.card.first, it.card.last].reject(&:empty?).join(" ")
            {"id" => it.id, "source_id" => it.source_id, "name" => person, "status" => nil}
          }
        })
        plan.save
        plan
      end

      # Every plan under dir, oldest first: a plan's directory is named
      # for the minute it was built, so the names sort as the plans do.
      #: (Pathname dir) -> Array[Plan]
      def self.all(dir)
        Pathname.glob("#{dir}/*/plan.yml").sort_by { it.dirname.basename.to_s }.map { read(it.dirname) }
      end

      #: (Pathname dir) -> Plan
      def self.read(dir)
        new(dir, YAML.safe_load_file(dir / "plan.yml"))
      end

      attr_reader :dir #: Pathname

      #: (Pathname dir, Hash[String, untyped] manifest) -> void
      def initialize(dir, manifest)
        format = manifest.fetch("format")
        raise ArgumentError, "#{dir} is plan format #{format}, and this reads #{FORMAT}" unless format == FORMAT

        @dir = dir
        @manifest = manifest
      end

      #: () -> String
      def source = @manifest.fetch("source")

      #: () -> String
      def created_at = @manifest.fetch("created_at")

      #: () -> String
      def group = @manifest.fetch("group")

      # The host the plan is landing on, once execute has started.
      #: () -> String?
      def host = @manifest.fetch("host")

      #: (String host) -> void
      def host=(host)
        @manifest["host"] = host
        save
      end

      #: () -> Array[Contact]
      def contacts
        @manifest.fetch("contacts").map {
          Contact.new(id: it.fetch("id"), source_id: it.fetch("source_id"), name: it.fetch("name"), status: it.fetch("status"))
        }
      end

      #: (String id, String status) -> void
      def record(id, status)
        @manifest.fetch("contacts").find { it.fetch("id") == id }.store("status", status)
        save
      end

      # The contacts this far along, for a task picking a plan to carry
      # further: none for a plan every step has finished.
      #: (String? status) -> Array[Contact]
      def with_status(status) = contacts.select { it.status == status }

      # The card as its file now reads, edits included.
      #: (String id) -> Card
      def card(id)
        Card.read(dir / "cards/#{id}.yml")
      end

      # Every step is saved as it is taken, and replaced whole by a rename
      # so a run that dies mid-write leaves the plan as it was before.
      #: () -> void
      def save
        written = dir / "plan.yml.tmp"
        written.open("w") do |file|
          file.write(YAML.dump(@manifest))
          file.fsync
        end
        written.rename(dir / "plan.yml")
      end
    end
  end
end
