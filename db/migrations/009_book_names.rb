# A login's book can go by a name other than the login, so the group
# choosing it reads `sync:Alpha Chen` rather than
# `sync:alpha@example.com` (docs/plans/2026-09-16-book-names.md).
#
# Both columns are exact bytes, the comparison Store#book makes, and a
# name is one login's for 008's reason: two logins sharing it would
# share a book.
#
# Like the groups, nothing can re-derive a row here. No timestamps, the
# birthdays' reason: a row is current state, replaced wholesale.
Sequel.migration do
  change do
    create_table(:book_names, strict: true) do
      String :login, text: true, null: false, primary_key: true
      String :name, text: true, null: false, unique: true
    end
  end
end
