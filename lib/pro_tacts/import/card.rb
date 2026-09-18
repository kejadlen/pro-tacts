require "base64"
require "yaml"

require "pro_tacts/admin/card_form"
require "pro_tacts/birthday"
require "pro_tacts/contact"

module ProTacts
  module Import
    # One contact in a plan, as the file a person edits before execute:
    # the fields the web editor has, and the groups it belongs to
    # (docs/plans/2026-09-16-importing-from-macos.md, "A card is a form
    # filled in"). Signed in sig/pro_tacts/import.rbs, being a Data class.
    # @rbs skip
    Card = Data.define(:first, :last, :nickname, :birthday, :phones, :emails, :addresses, :note, :photo, :groups, :source)

    # Reopened for the reason VCard::Parser::Property is.
    class Card
      # A card file that will not read as one.
      class Invalid < StandardError; end

      KEYS = %w[first last nickname birthday phones emails addresses note photo groups source].freeze #: Array[String]

      # What the source gave, kept in the card rather than off to the
      # side: the fields above are read out of it, and `remove` compares
      # the Mac's contact against it before deleting anything, so the two
      # are read together and edited in one place.
      SOURCE_KEYS = %w[identifier vcard note contact].freeze #: Array[String]

      # An address's parts, as the editor's own add row names them
      # (Admin::CardForm's ADDRESS_COMPONENTS, which is private to it).
      # No post office box: no screen shows one either.
      ADDRESS_KEYS = %w[extended street locality region postal_code country].freeze #: Array[String]

      BIRTHDAY = /\A(\d{4})-(\d{2})-(\d{2})\z/ #: Regexp

      # A picture's format as `PHOTO`'s TYPE names it, read off the
      # decoded bytes the way Contact#photo reads one back: the magic
      # bytes cannot mislabel what they are.
      PHOTO_TYPES = {"image/jpeg" => "JPEG", "image/png" => "PNG", "image/gif" => "GIF"}.freeze #: Hash[String, String]

      # Every problem is refused rather than skipped: a key this does not
      # know, or a value YAML read as something other than text (an
      # unquoted `no` is false, and an unquoted 1815-12-10 a Date), is an
      # edit that would otherwise vanish.
      #: (Pathname path) -> Card
      def self.read(path)
        document = YAML.safe_load_file(path)
        invalid = ->(why) { raise Invalid, "#{path}: #{why}" }
        invalid.("is not a mapping") unless document.is_a?(Hash)

        missing = KEYS - document.keys
        invalid.("has no #{missing.join(", ")}") unless missing.empty?
        unknown = document.keys - KEYS
        invalid.("has #{unknown.join(", ")}, which no field takes") unless unknown.empty?

        first, last, nickname, birthday, phones, emails, addresses, note, photo, groups, source = document.values_at(*KEYS)
        invalid.("first and last must be text; quote them") unless first.is_a?(String) && last.is_a?(String)
        invalid.("needs a first or last name") if first.strip.empty? && last.strip.empty?
        invalid.("nickname must be text, or blank") unless nickname.nil? || nickname.is_a?(String)
        invalid.("birthday must be a quoted YYYY-MM-DD, or blank") unless birthday.nil? || birthday.is_a?(String) && birthday.match?(BIRTHDAY)
        invalid.("phones must be a list of quoted numbers") unless texts?(phones)
        invalid.("emails must be a list of addresses") unless texts?(emails)
        addresses.is_a?(Array) && addresses.all? { address?(it) } or
          invalid.("addresses must be a list, each with any of #{ADDRESS_KEYS.join(", ")}")
        invalid.("groups must be a list of names") unless texts?(groups) && groups.none? { it.strip.empty? }
        invalid.("note must be text, or blank") unless note.nil? || note.is_a?(String)
        invalid.("photo must be true or false") unless [true, false].include?(photo)
        invalid.("source must hold #{SOURCE_KEYS.join(", ")}") unless source?(source)
        card = new(first:, last:, nickname:, birthday:, phones:, emails:, addresses:, note:, photo:, groups:, source:)
        invalid.("photo is true and the source holds no picture this server knows") if photo && card.picture.nil?

        card
      rescue Psych::DisallowedClass => error
        raise Invalid, "#{path}: #{error.message.sub(/\ATried to load unspecified class: /, "reads as a ")}; quote it"
      end

      #: (untyped value) -> bool
      def self.texts?(value)
        value.is_a?(Array) && value.all?(String)
      end

      #: (untyped value) -> bool
      def self.address?(value)
        value.is_a?(Hash) && (value.keys - ADDRESS_KEYS).empty? &&
          value.values.all?(String) && value.values.any? { !it.strip.empty? }
      end

      #: (untyped value) -> bool
      def self.source?(value)
        value.is_a?(Hash) && value.keys.sort == SOURCE_KEYS.sort &&
          value.fetch("identifier").is_a?(String) && value.fetch("vcard").is_a?(String) &&
          [NilClass, String].include?(value.fetch("note").class) && value.fetch("contact").is_a?(Hash)
      end

      private_class_method :texts?, :address?, :source?

      # The contact the web create and then the editor's add rows would
      # make of these fields. The birthday rides beside the card as the
      # store keeps it, and Contact composes the line back in
      # (docs/plans/2026-09-11-every-birthday-in-the-model.md).
      # No middle name: a plan's card holds first and last, and a source
      # N carrying anything past them is refused rather than imported
      # (Macos.name), so there is none here to write.
      #: (String id) -> Contact
      def contact(id)
        created = Contact.new(id:, stored: Admin::CardForm.new_card(id, first, "", last), birthday: nil, inherited: [])
        stored = Admin::CardForm.contact_card(created, first, "", last, {
          "nickname" => nickname.to_s, "note" => note.to_s,
          "new_phone" => phones, "new_email" => emails, "new_address" => addresses
        })
        # The picture has no field on any form, the editor showing one
        # rather than taking one, so its line is written here.
        stored = stored.insert([picture].compact)
        Contact.new(id:, stored:, birthday: born_on, inherited: [])
      end

      # The source's picture as a PHOTO line, or nil for a card that
      # carries none and for data that decodes to no format the server
      # knows — which Card.read refuses rather than dropping.
      #: () -> String?
      def picture
        return unless photo

        data = source.fetch("contact")["imageData"] #: untyped
        return unless data.is_a?(String)

        bytes = begin
          Base64.strict_decode64(data)
        rescue ArgumentError
          return
        end
        signature = Contact::PHOTO_SIGNATURES.find { bytes.start_with?(it.first) }
        return if signature.nil?

        "PHOTO;ENCODING=b;TYPE=#{PHOTO_TYPES.fetch(signature.last)}:#{data}\r\n"
      end

      #: () -> Birthday?
      def born_on
        captures = birthday&.match(BIRTHDAY)&.captures
        return if captures.nil?

        year, month, day = captures
        Birthday.new(year: Integer(year), month: Integer(month), day: Integer(day))
      end

      #: () -> Hash[String, untyped]
      def document
        KEYS.zip([first, last, nickname, birthday, phones, emails, addresses, note, photo, groups, source]).to_h
      end
    end
  end
end
