# Contacts whose ids this server did not mint: a client's creates
# arrive as UUIDs (macOS mints one into both the URI and the card's
# UID), and the seeds predate the shape. Store#reid moves each onto an
# id of the server's own — a change every syncing client hears through
# the change log's delete-and-put pair, hrefs and all.

namespace :contacts do
  desc "Re-id contacts whose ids are not server-minted (client UUIDs and old seeds)"
  task :reid do
    require "pro_tacts"
    require "pro_tacts/store"

    ProTacts::Store.connect(ProTacts.config.database_path) do |store|
      unminted = store.contacts.reject { ProTacts::ChangeId.minted?(it.id) }
      if unminted.empty?
        puts "every contact's id is server-minted"
      else
        unminted.each do |contact|
          puts "#{contact.id} -> #{store.reid(contact.id)}"
        end
      end
    end
  end
end
