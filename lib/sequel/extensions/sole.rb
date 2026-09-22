
require "sequel"

module Sequel
  # The row a filter identifies, or a raise.
  #
  # A filter meant to identify one row — a lookup by primary key, later
  # the group that contributed a property to a card — reads naturally as
  # `first`, and `first` answers with one of several without a word when
  # the filter turns out not to identify anything. That is the failure
  # worth catching: the query claimed one row, so anything else is a
  # broken assumption rather than a result to pick from.
  #
  # Both ways of being wrong raise, so the assertion is in one method
  # rather than split across a pair. A caller for whom no row is
  # ordinary says so by rescuing Sequel::NoMatchingRow, which is the
  # error Sequel's own `first!` raises for it.
  #
  # Load it with `DB.extension(:sole)`, which reaches every dataset the
  # database makes.
  # @rbs module-self: Sequel::_Queryable -- it is mixed into datasets
  module Sole
    # More rows than the query said there could be. A Sequel::Error, so
    # it is caught by anything already catching database failures.
    class TooManyRows < Sequel::Error; end

    #: () -> Hash[Symbol, untyped]
    def sole
      # Two is enough to know, and a LIMIT keeps a filter that turned out
      # to match the whole table from dragging it back to prove the
      # point. It replaces any limit already set, which is why this is
      # for identifying a row rather than for sampling one.
      rows = limit(2).all

      # The table rather than the SQL: a filter can carry card content,
      # and an exception message is one of the things that reaches
      # Sentry.
      raise TooManyRows, "more than one row in #{first_source}" if rows.length > 1
      raise Sequel::NoMatchingRow.new(self) if rows.empty?

      rows.fetch(0)
    end

    # The same read where no row is the ordinary answer — an href
    # nobody has, a login whose book was never named — so the caller
    # says so once here rather than spelling the rescue out again.
    # Only the empty case: more rows than the filter claimed is still
    # the broken assumption #sole exists to raise on.
    #: () -> Hash[Symbol, untyped]?
    def sole_or_nil
      sole
    rescue Sequel::NoMatchingRow
      nil
    end
  end

  Dataset.register_extension(:sole, Sole)
  Database.register_extension(:sole) { |db| db.extend_datasets(Sole) }
end
