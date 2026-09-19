require "yaml"

module ProTacts
  module Import
    # The standing data the import tasks keep between plans, read from
    # data/import/config.yml, at the root of the import collateral
    # under data/import. Not committed — /data is ignored — because it
    # holds this deployment's own host and choices. Each key of the
    # file is a member, grown one at a time as the tasks take standing
    # data off the command line.
    # @rbs skip
    class Config < Data.define(:host)
      # Every problem is refused rather than skipped, naming the file —
      # Card#read's rules for a hand-edited file. The host is required
      # rather than nil-able: the tasks that read this are the ones
      # with a host to land on, and a config that names none fails at
      # the read, before any plan is picked.
      def self.read(path)
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
        new(host:)
      end
    end
  end
end
