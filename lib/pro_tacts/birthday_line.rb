require "pro_tacts/birthday"
require "pro_tacts/vcard/parser"

module ProTacts
  # What one BDAY line in a submitted card is, for Store#put to act on
  # (docs/plans/2026-09-11-every-birthday-in-the-model.md). Match with
  # case/when, not case/in: Steep does not check the bodies of case/in
  # branches, and these branches are the ones worth checking.
  #
  # The variants are signed in sig/pro_tacts/birthday_line.rbs, for
  # Birthday's reason.
  module BirthdayLine
    # A birthday the model takes: the line leaves the card.
    # @rbs skip
    class Modeled < Data.define(:birthday)
    end

    # A line that reads as a BDAY the model does not take. It stays in
    # the card verbatim and is reported.
    # @rbs skip
    class Unrecognized < Data.define
    end

    # A line the parser could not read as a BDAY at all. It stays in the
    # card, and Web#report_unreadable_lines has already reported it.
    # @rbs skip
    class Unreadable < Data.define
    end

    # The line's property is checked by name as well as read, because a
    # line matched as BDAY by its bytes can still fail to parse into one.
    #: (VCard::Parser::Line line) -> (Modeled | Unrecognized | Unreadable)
    def self.read(line)
      property = line.property
      return Unreadable.new unless property&.name&.casecmp?("BDAY")

      birthday = Birthday.from_property(property)
      birthday ? Modeled.new(birthday:) : Unrecognized.new
    end
  end
end
