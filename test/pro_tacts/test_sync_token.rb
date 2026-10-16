require_relative "../test_helper"

require "hegel"

require "pro_tacts/sync_token"

class SyncTokenTest < Minitest::Test
  include Hegel::Syntax::Methods

  BOOK = ProTacts::SyncToken.book("alpha@example.com")
  DATABASE = "0f1e2d3c4b5a6978" #: String

  def test_a_minted_token_reads_back_as_its_sequence
    assert_equal 22, ProTacts::SyncToken.read(ProTacts::SyncToken.mint("22", BOOK, DATABASE), BOOK, DATABASE)
  end

  # Zero is what a book nothing has been written to carries, and it has
  # to read back as a sequence rather than as no token at all.
  def test_the_zero_sequence_reads_back
    assert_equal 0, ProTacts::SyncToken.read(ProTacts::SyncToken.mint("0", BOOK, DATABASE), BOOK, DATABASE)
  end

  def test_another_books_token_reads_as_nothing
    other = ProTacts::SyncToken.book("zed@example.com")

    assert_nil ProTacts::SyncToken.read(ProTacts::SyncToken.mint("22", other, DATABASE), BOOK, DATABASE)
  end

  def test_another_databases_token_reads_as_nothing
    other = "1111111111111111"

    assert_nil ProTacts::SyncToken.read(ProTacts::SyncToken.mint("22", BOOK, other), BOOK, DATABASE)
  end

  # The shapes macOS was recorded sending before tokens named their
  # database: no book at all (fixture 08), and a book but no database
  # (fixture 12's request).
  def test_a_token_from_before_databases_reads_as_nothing
    assert_nil ProTacts::SyncToken.read("http://pro-tacts/sync/1", BOOK, DATABASE)
    assert_nil ProTacts::SyncToken.read("http://pro-tacts/sync/22/#{BOOK}", BOOK, DATABASE)
  end

  def test_anything_that_is_not_a_token_reads_as_nothing
    ["", "1", "http://pro-tacts/sync//#{BOOK}/#{DATABASE}", "http://pro-tacts/sync/22/#{BOOK}/#{DATABASE}/"].each do |text|
      assert_nil ProTacts::SyncToken.read(text, BOOK, DATABASE), text
    end
  end

  def test_a_book_is_sixteen_hex_digits_of_its_login
    assert_match(/\A[0-9a-f]{16}\z/, BOOK)
    refute_equal BOOK, ProTacts::SyncToken.book("zed@example.com")
  end

  ## Property tests

  def database_id = from_regex("[0-9a-f]{16}", fullmatch: true)

  # Any sequence a book's ctag reaches, minted for any login's book on
  # any database, reads back as that sequence there.
  def test_any_minted_token_reads_back_as_its_sequence
    Hegel.test(test_cases: 1_000) do |tc|
      sequence = tc.draw(integers(min_value: 0))
      book = ProTacts::SyncToken.book(tc.draw(text))
      database = tc.draw(database_id)

      assert_equal sequence, ProTacts::SyncToken.read(ProTacts::SyncToken.mint(sequence.to_s, book, database), book, database)
    end
  end

  # And reads as nothing anywhere else: on another book or another
  # database, a token is one this server never minted for it.
  def test_a_token_reads_as_nothing_off_the_book_and_database_that_minted_it
    Hegel.test(test_cases: 1_000) do |tc|
      sequence = tc.draw(integers(min_value: 0)).to_s
      minted_for = [ProTacts::SyncToken.book(tc.draw(text)), tc.draw(database_id)]
      read_on = [ProTacts::SyncToken.book(tc.draw(text)), tc.draw(database_id)]
      tc.assume(minted_for != read_on)

      assert_nil ProTacts::SyncToken.read(ProTacts::SyncToken.mint(sequence, *minted_for), *read_on)
    end
  end
end
