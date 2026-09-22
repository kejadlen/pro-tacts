require_relative "../../test_helper"

require "sequel"
require "tmpdir"

require "sequel/extensions/sole"

class SoleTest < Minitest::Test
  def with_rows(ids)
    Dir.mktmpdir do |dir|
      database = Sequel.sqlite("#{dir}/t.db")
      database.extension(:sole)
      database.create_table(:things) do
        String :id
        String :body
      end
      ids.each do |id|
        database[:things].insert(id:, body: "body of #{id}")
      end
      yield database[:things]
    end
  end

  def test_the_one_row_comes_back
    with_rows(%w[a b]) do |things|
      assert_equal "body of a", things.where(id: "a").sole.fetch(:body)
    end
  end

  # Sequel's own `first!` raises this for an empty dataset, so a caller
  # for whom no row is ordinary has one error to name.
  def test_no_rows_raises
    with_rows(%w[a]) do |things|
      assert_raises(Sequel::NoMatchingRow) { things.where(id: "nobody").sole }
    end
  end

  # The half `first` gets wrong: it would answer with one of the two.
  def test_more_than_one_row_raises
    with_rows(%w[a a]) do |things|
      assert_raises(Sequel::Sole::TooManyRows) { things.where(id: "a").sole }
    end
  end

  # An exception message is one of the things that reaches Sentry, and a
  # filter can carry card content, so the message names the table only.
  def test_the_message_names_the_table_and_not_the_query
    with_rows(%w[a a]) do |things|
      error = assert_raises(Sequel::Sole::TooManyRows) { things.where(body: "body of a").sole }

      assert_equal "more than one row in things", error.message
      refute_includes error.message, "body of a"
    end
  end

  def test_it_is_a_sequel_error
    assert_operator Sequel::Sole::TooManyRows, :<, Sequel::Error
  end

  # Everything Sequel logs, which is how the query itself is inspected.
  class QueryLog
    attr_reader :queries

    def initialize
      @queries = []
    end

    def info(message)
      @queries << message
    end
    alias_method :error, :info
  end

  # A filter that turned out to match every row must not drag them all
  # back to prove it.
  def test_it_reads_two_rows_at_most
    with_rows(%w[a a a a a]) do |things|
      log = QueryLog.new
      things.db.loggers << log

      assert_raises(Sequel::Sole::TooManyRows) { things.sole }
      assert(log.queries.any? { it.include?("LIMIT 2") }, log.queries.inspect)
    end
  end
end
