require "pathname"
require "uri"
require "yaml"

module ProTacts
  module Import
    # The import tasks' world under data/import: where everything
    # lives — the paths below — and the standing data kept between
    # plans, read from config.yml as the members of the Data. Not
    # committed — /data is ignored — because it holds this
    # deployment's own host and choices. Each key of the file is a
    # member, grown one at a time as the tasks take standing data off
    # the command line.
    # @rbs skip
    class Config < Data.define(:host)
      # The root of the import collateral: the standing data in FILE,
      # the plans in flight under ACTIVE, filed away under DONE once
      # every contact is off this Mac — the two states a plan's
      # directory names, beside the one file that outlives them.
      ROOT = Pathname.new("data/import")
      FILE = ROOT / "config.yml"
      ACTIVE = ROOT / "active"
      DONE = ROOT / "done"

      # Every problem is refused rather than skipped, naming the file —
      # Card#read's rules for a hand-edited file. The host is required
      # rather than nil-able, and parsed: a bare hostname is the base
      # URL of a server that serves HTTPS, which every deployment
      # does, so the scheme is spelled out — the host a plan records
      # is the one a second run is compared against — and anything
      # that is not an http or https URL is refused.
      def self.read(path = FILE)
        invalid = ->(why) { raise ArgumentError, "#{path}: #{why}" }
        invalid.("does not exist") unless path.file?

        document = YAML.safe_load_file(path)
        invalid.("has no host") if document.nil?
        invalid.("is not a mapping") unless document.is_a?(Hash)
        unknown = document.keys - members.map(&:to_s)
        invalid.("has #{unknown.join(", ")}, which no member takes") unless unknown.empty?

        host = document.fetch("host", nil)
        invalid.("has no host") if host.nil?
        invalid.("host must be text") unless host.is_a?(String)
        invalid.("host is blank") if host.strip.empty?

        begin
          uri = URI.parse(host)
          uri = URI.parse("https://#{uri}") if uri.scheme.nil?
        rescue URI::InvalidURIError
          invalid.("host does not read as a URL")
        end
        unless uri.is_a?(URI::HTTP)
          raise ArgumentError, "#{path}: host must be an http or https URL, such as https://contacts"
        end

        new(host: uri)
      end
    end
  end
end
