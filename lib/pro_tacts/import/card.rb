require "yaml"

require "pro_tacts/admin/card_form"
require "pro_tacts/contact"

module ProTacts
  module Import
    # One contact in a plan, as the file a person edits before execute:
    # the fields the web editor has, and the groups to join
    # (docs/plans/2026-09-16-importing-from-macos.md, "A card is a form
    # filled in"). Signed in sig/pro_tacts/import.rbs, being a Data class.
    # @rbs skip
    Card = Data.define(:first, :last, :phones, :groups)

    # Reopened for the reason VCard::Parser::Property is.
    class Card
      # A card file that will not read as one.
      class Invalid < StandardError; end

      KEYS = %w[first last phones groups].freeze #: Array[String]

      # Every problem is refused rather than skipped: a key this does not
      # know, or a value YAML read as something other than text (an
      # unquoted `no` is false), is an edit that would otherwise vanish.
      #: (Pathname path) -> Card
      def self.read(path)
        document = YAML.safe_load_file(path)
        invalid = ->(why) { raise Invalid, "#{path}: #{why}" }
        invalid.("is not a mapping") unless document.is_a?(Hash)

        missing = KEYS - document.keys
        invalid.("has no #{missing.join(", ")}") unless missing.empty?
        unknown = document.keys - KEYS
        invalid.("has #{unknown.join(", ")}, which no field takes") unless unknown.empty?

        first, last, phones, groups = document.values_at(*KEYS)
        invalid.("first and last must be text; quote them") unless first.is_a?(String) && last.is_a?(String)
        invalid.("needs a first or last name") if first.strip.empty? && last.strip.empty?
        invalid.("phones must be a list of quoted numbers") unless texts?(phones)
        invalid.("groups must be a list of names") unless texts?(groups) && groups.none? { it.strip.empty? }

        new(first:, last:, phones:, groups:)
      end

      #: (untyped value) -> bool
      def self.texts?(value)
        value.is_a?(Array) && value.all?(String)
      end

      private_class_method :texts?

      # The contact the web create and then the editor's add rows would
      # make of these fields.
      #: (String id) -> Contact
      def contact(id)
        created = Contact.new(id:, stored: Admin::CardForm.new_card(id, first, last), birthday: nil, inherited: [])
        stored = Admin::CardForm.contact_card(created, first, last, {"new_phone" => phones})
        Contact.new(id:, stored:, birthday: nil, inherited: [])
      end

      #: () -> Hash[String, untyped]
      def document
        {"first" => first, "last" => last, "phones" => phones, "groups" => groups}
      end
    end
  end
end
