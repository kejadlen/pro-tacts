# The index is a projection of the stored cards and nothing is
# authoritative in it, so rebuilding is always safe: run this after a
# change to how cards are parsed, or if the index is ever suspected of
# disagreeing with the cards. See ProTacts::Store.

namespace :index do
  desc "Drop the derived index and rebuild it from the stored cards"
  task :rebuild do
    require "pro_tacts"
    require "pro_tacts/store"

    database = ProTacts.config.database_path
    ProTacts::Store.connect(database) do |store|
      store.rebuild_index
      puts "rebuilt the index in #{database}"
    end
  end
end
