require "fileutils"
require "json"
require "pathname"
require "time"

module ProTacts
  module Import
    # One import, as a directory: what a source builder decided, and how
    # far execute and remove have carried it
    # (docs/plans/2026-09-16-importing-from-macos.md).
    class Plan
      # @rbs @dir: Pathname
      # @rbs @manifest: Hash[String, untyped]

      # What a builder hands over for one contact: the card execute PUTs
      # and the original's files, by name. Signed in
      # sig/pro_tacts/import.rbs, being a Data class.
      # @rbs skip
      Entry = Data.define(:id, :source_id, :card, :backup)

      # A contact as the plan lists it, with the last step it reached:
      # nil, then landed, joined, and removed, in that order.
      # @rbs skip
      Contact = Data.define(:id, :source_id, :status)

      FORMAT = 1 #: Integer

      #: (Pathname dir, source: String, created_at: Time, entries: Array[Entry]) -> Plan
      def self.write(dir, source:, created_at:, entries:)
        FileUtils.mkdir_p(dir.dirname)
        # Raises when the directory is there, so no plan is written over
        # another.
        Dir.mkdir(dir)

        entries.each do |entry|
          (dir / "cards").mkpath
          (dir / "cards/#{entry.id}.vcf").binwrite(entry.card)
          backup = dir / "backups" / entry.id
          backup.mkpath
          entry.backup.each { |name, bytes| (backup / name).binwrite(bytes) }
        end

        plan = new(dir, {
          "format" => FORMAT,
          "source" => source,
          "created_at" => created_at.utc.iso8601,
          "group" => "import-#{created_at.utc.strftime("%Y%m%dT%H%M%SZ")}",
          "host" => nil,
          "group_id" => nil,
          "contacts" => entries.map { {"id" => it.id, "source_id" => it.source_id, "status" => nil} }
        })
        plan.save
        plan
      end

      #: (Pathname dir) -> Plan
      def self.read(dir)
        new(dir, JSON.parse((dir / "plan.json").read))
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

      #: () -> String?
      def group_id = @manifest.fetch("group_id")

      #: (String id) -> void
      def group_id=(id)
        @manifest["group_id"] = id
        save
      end

      #: () -> Array[Contact]
      def contacts
        @manifest.fetch("contacts").map { Contact.new(id: it.fetch("id"), source_id: it.fetch("source_id"), status: it.fetch("status")) }
      end

      #: (String id, String status) -> void
      def record(id, status)
        @manifest.fetch("contacts").find { it.fetch("id") == id }.store("status", status)
        save
      end

      #: (String id) -> String
      def card(id)
        (dir / "cards/#{id}.vcf").binread
      end

      # Every step is saved as it is taken, and replaced whole by a rename
      # so a run that dies mid-write leaves the plan as it was before.
      #: () -> void
      def save
        written = dir / "plan.json.tmp"
        written.open("w") do |file|
          file.write(JSON.pretty_generate(@manifest))
          file.fsync
        end
        written.rename(dir / "plan.json")
      end
    end
  end
end
