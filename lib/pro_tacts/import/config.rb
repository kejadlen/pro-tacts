require "yaml"

module ProTacts
  module Import
    # The standing data the import tasks keep between plans, as a YAML
    # mapping: data/import/config.yml, beside the plans under
    # data/imports. Not committed — /data is ignored — because it holds
    # this deployment's own host and choices. The keys are the tasks'
    # to grow as they take standing data off the command line.
    class Config
      # A missing file is no configuration and an empty one is none
      # either; a file whose top level is not a mapping is refused
      # rather than half-read, naming the file.
      #: (Pathname path) -> Hash[untyped, untyped]
      def self.read(path)
        return {} unless path.file?

        document = YAML.safe_load_file(path)
        return {} if document.nil?

        unless document.is_a?(Hash)
          raise ArgumentError, "#{path} is not a YAML mapping"
        end

        document
      end
    end
  end
end
