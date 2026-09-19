require_relative "../test_helper"

require "pathname"
require "rake"
require "tmpdir"

require "pro_tacts/change_id"
require "pro_tacts/store"
require "pro_tacts/vcard"

class ContactsTasksTest < Minitest::Test
  # The id a macOS create mints into both the URI and the card's UID,
  # and the one the server itself would have minted.
  UUID = "AB12C345-6789-0DEF-1234-567890ABCDEF" #: String
  MINTED = "zzzzzzzzzzzz" #: String

  def test_reid_moves_the_contacts_the_server_did_not_mint
    Dir.mktmpdir do |root|
      root = Pathname.new(root)
      ProTacts::Store.connect(root / "contacts.db") do |store|
        store.put(UUID, vcard("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:#{UUID}\r\nEND:VCARD\r\n"))
        store.put(MINTED, vcard("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Zed\r\nUID:#{MINTED}\r\nEND:VCARD\r\n"))

        out, = run_task(root)

        assert_match(/\A#{UUID} -> [k-z]{12}\n\z/, out)
        ids = store.contacts.map { it.id }
        assert_includes ids, MINTED
        assert ids.all? { ProTacts::ChangeId.minted?(it) }

        out, = run_task(root)
        assert_equal "every contact's id is server-minted\n", out
      end
    end
  end

  private

  # A card from bytes, the shape Store#put takes.
  def vcard(bytes) = ProTacts::VCard.new(bytes)

  # Runs contacts:reid in a Rake application of its own, with root as
  # the data directory.
  def run_task(root)
    config = ProTacts.config
    application = Rake.application

    ProTacts.config = ProTacts::Config.new("PRO_TACTS_DATA_DIR" => root.to_s)
    Rake.application = Rake::Application.new
    load (Pathname.new(__dir__).parent.parent / "tasks" / "contacts.rake").to_s
    capture_io { Rake.application["contacts:reid"].invoke }
  ensure
    ProTacts.config = config
    Rake.application = application
  end
end
