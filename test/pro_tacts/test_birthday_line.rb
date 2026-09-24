require_relative "../test_helper"

require "pro_tacts/birthday"
require "pro_tacts/birthday_line"
require "pro_tacts/vcard"

# The birthday half of a write on its own, with no store behind it.
# test_store.rb holds the same rules through Store#put, where the
# birthdays row and the served card are what is checked.
class BirthdayLineTest < Minitest::Test
  include Sentry::TestHelper
  include SentryMessages

  AIDEN = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"
  APRIL_12 = ProTacts::Birthday.new(year: 1985, month: 4, day: 12)

  def setup
    setup_sentry
  end

  def teardown
    teardown_sentry_test
  end

  def vcard(bytes) = ProTacts::VCard.new(bytes)

  def with_lines(*lines) = AIDEN.sub("END:VCARD\r\n", lines.map { "#{it}\r\n" }.join + "END:VCARD\r\n")

  def split(bytes, existing: nil, stored_before: nil)
    ProTacts::BirthdayLine.split(vcard(bytes), existing, stored_before && vcard(stored_before))
  end

  def test_a_modeled_birthday_leaves_the_card_for_the_model
    birthday, rest = split(with_lines("BDAY:1985-04-12"))

    assert_equal APRIL_12, birthday
    assert_equal AIDEN, rest.to_s
    assert_empty sentry_messages
  end

  def test_a_card_without_a_bday_keeps_a_birthday_no_client_was_sent
    month_only = ProTacts::Birthday.new(month: 4)

    assert_equal month_only, split(AIDEN, existing: month_only).first
  end

  def test_a_card_without_a_bday_drops_a_birthday_the_client_was_sent
    assert_nil split(AIDEN, existing: APRIL_12).first
  end

  def test_an_unrecognized_bday_stays_in_the_card_and_is_reported
    submitted = with_lines("BDAY:1985-13")
    birthday, rest = split(submitted)

    assert_nil birthday
    assert_equal submitted, rest.to_s
    assert_equal ["a submitted card carried a BDAY line the model does not take"], sentry_messages
  end

  def test_several_bday_lines_stay_in_the_card_and_are_reported
    submitted = with_lines("BDAY:1985-04-12", "BDAY:1986-05-13")
    birthday, rest = split(submitted)

    assert_nil birthday
    assert_equal submitted, rest.to_s
    assert_equal ["a submitted card carried 2 BDAY lines"], sentry_messages
  end

  def test_a_write_dropping_a_bday_the_model_did_not_take_is_reported
    split(AIDEN, stored_before: with_lines("BDAY:1985-13"))

    assert_equal ["a write dropped 1 BDAY line(s) the model did not take"], sentry_messages
  end
end
