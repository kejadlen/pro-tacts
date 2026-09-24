require "sentry-ruby"

require "pro_tacts/birthday"
require "pro_tacts/vcard"
require "pro_tacts/vcard/parser"

module ProTacts
  # What one BDAY line in a submitted card is, and the split Store#put
  # makes on it (docs/plans/2026-09-11-every-birthday-in-the-model.md).
  # Match with case/when, not case/in: Steep does not check the bodies
  # of case/in branches, and these branches are the ones worth checking.
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

    # The birthday half of the split a write makes: the model's new
    # birthday, and the card to store beside it. A card holds at most
    # one BDAY, and one that reads as a birthday leaves the card for the
    # model. Any other stays in the card byte for byte, reported, with
    # the model emptied so nothing composes a second BDAY beside it
    # (RFC 6352 section 6.3.2.2).
    #
    # No BDAY is a client that was sent the birthday removing it, or
    # one that was never sent it and so cannot have. A BDAY line left
    # in the stored card goes with the write, which is worth saying.
    #
    # case/when for the module's reason, which is what the last arm is
    # for.
    #: (VCard vcard, Birthday? existing, VCard? stored_before) -> [Birthday?, VCard]
    def self.split(vcard, existing, stored_before)
      bdays, rest = vcard.extract("BDAY")
      if bdays.empty?
        report_lost(stored_before)
        return [existing && !existing.served? ? existing : nil, vcard]
      end

      if bdays.length > 1
        report_many(bdays.length)
        return [nil, vcard]
      end

      line = read(bdays.fetch(0))
      case line
      when Modeled
        [line.birthday, rest]
      when Unrecognized
        report_unrecognized
        [nil, vcard]
      when Unreadable
        [nil, vcard]
      else
        raise "no arm for #{line.class}"
      end
    end

    # The arrival report: a BDAY the model does not take is unexpected
    # input, and storing it verbatim would be the last anyone heard of
    # it. The message carries no card content
    # (the line config.ru draws for Sentry); the value stays on the
    # machine, where the admin view shows it raw.
    #: () -> void
    def self.report_unrecognized
      Sentry.capture_message("a submitted card carried a BDAY line the model does not take", level: :warning)
    end

    # A contact has one birthday, so a card with several cannot say
    # which it means, whatever each line holds.
    #: (Integer count) -> void
    def self.report_many(count)
      Sentry.capture_message("a submitted card carried #{count} BDAY lines", level: :warning)
    end

    # The loss report, the write's half of the arrival one: a BDAY line
    # still in the stored card is one the model did not take, and a
    # write without it is about to drop it with nobody told.
    #: (VCard? stored_before) -> void
    def self.report_lost(stored_before)
      return if stored_before.nil?

      lines, = stored_before.extract("BDAY")
      return if lines.empty?

      Sentry.capture_message("a write dropped #{lines.length} BDAY line(s) the model did not take", level: :warning)
    end

    private_class_method :report_unrecognized, :report_many, :report_lost
  end
end
