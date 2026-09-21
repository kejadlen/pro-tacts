# The table is named for what a row is rather than for its one column.
# A book is what a login syncs (Store#book_cards), and a row here is
# one that goes by a name of its own; `book_names` named the table
# after the `name` column, leaving the word for the thing and the word
# for the table at odds (docs/plans/2026-09-21-books-not-book-names.md).
#
# A rename and nothing else. SQLite carries a table's own constraints
# over with it, so 009's two rules — a login holds one row, a name is
# one login's — still hold, and no row moves.
Sequel.migration do
  change do
    rename_table :book_names, :books
  end
end
