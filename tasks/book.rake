# The name a login's book goes by, in place of the login
# (docs/plans/2026-09-16-book-names.md).

namespace :book do
  desc "Name LOGIN's book NAME, renaming its sync group (no NAME goes back to the login)"
  task :name do
    require "pro_tacts"
    require "pro_tacts/store"

    login = ENV.fetch("LOGIN")
    ProTacts::Store.connect(ProTacts.config.database_path) do |store|
      store.name_book(login, ENV.fetch("NAME", nil))
      puts "#{login} syncs #{ProTacts::Group::SYNC_PREFIX}#{store.book_name(login)}"
    end
  end
end
