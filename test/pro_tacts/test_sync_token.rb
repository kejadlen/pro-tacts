require_relative "../test_helper"

require "pro_tacts/sync_token"

class SyncTokenTest < Minitest::Test
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
  # (fixture 12's request, the spelling this change retires).
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
end
