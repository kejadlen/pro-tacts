require_relative "../test_helper"

require "pro_tacts/sync_token"

class SyncTokenTest < Minitest::Test
  BOOK = ProTacts::SyncToken.book("alpha@example.com")

  def test_a_minted_token_reads_back_as_its_sequence
    assert_equal 22, ProTacts::SyncToken.read(ProTacts::SyncToken.mint("22", BOOK), BOOK)
  end

  # Zero is what a book nothing has been written to carries, and it has
  # to read back as a sequence rather than as no token at all.
  def test_the_zero_sequence_reads_back
    assert_equal 0, ProTacts::SyncToken.read(ProTacts::SyncToken.mint("0", BOOK), BOOK)
  end

  def test_another_books_token_reads_as_nothing
    other = ProTacts::SyncToken.book("zed@example.com")

    assert_nil ProTacts::SyncToken.read(ProTacts::SyncToken.mint("22", other), BOOK)
  end

  # The shape macOS was recorded sending before books existed
  # (test/fixtures/macos-exchange/08-report-sync-collection).
  def test_a_token_from_before_books_reads_as_nothing
    assert_nil ProTacts::SyncToken.read("http://pro-tacts/sync/1", BOOK)
  end

  def test_anything_that_is_not_a_token_reads_as_nothing
    ["", "1", "http://pro-tacts/sync//#{BOOK}", "http://pro-tacts/sync/22/#{BOOK}/"].each do |text|
      assert_nil ProTacts::SyncToken.read(text, BOOK), text
    end
  end

  def test_a_book_is_sixteen_hex_digits_of_its_login
    assert_match(/\A[0-9a-f]{16}\z/, BOOK)
    refute_equal BOOK, ProTacts::SyncToken.book("zed@example.com")
  end
end
