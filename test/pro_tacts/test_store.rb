require_relative "../test_helper"

require "pathname"
require "tmpdir"

require "sequel"

require "pro_tacts/store"

class StoreTest < Minitest::Test
  AIDEN = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"
  # UTC ISO 8601 to the millisecond, which is what SQLite is asked for.
  TIMESTAMP = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/
  ZED = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Zed\r\nUID:znorth\r\nEND:VCARD\r\n"

  # A store on disk rather than in memory: WAL, the busy timeout, and
  # reopening a database are all part of what is under test.
  def with_store(cards = {})
    Dir.mktmpdir do |dir|
      ProTacts::Store.connect(Pathname.new(dir) / "contacts.db") do |store|
        cards.each do |id, card|
          store.put(id, card)
        end
        yield store
      end
    end
  end

  ## Cards

  def test_a_stored_card_comes_back_byte_for_byte
    with_store({"aiden" => AIDEN}) do |store|
      assert_equal AIDEN, store.contact("aiden").vcard
    end
  end

  def test_contacts_are_listed_by_id
    with_store({"znorth" => ZED, "aiden" => AIDEN}) do |store|
      assert_equal %w[aiden znorth], store.contacts.map { it.id }
    end
  end

  def test_an_empty_store_lists_no_contacts
    with_store { assert_empty it.contacts }
  end

  def test_a_missing_contact_is_nil
    with_store { assert_nil it.contact("nobody") }
  end

  def test_putting_the_same_id_replaces_the_card
    with_store({"aiden" => AIDEN}) do |store|
      updated = AIDEN.sub("Aiden", "Aiden Smith")
      store.put("aiden", updated)

      assert_equal [updated], store.contacts.map { it.vcard }
    end
  end

  def test_the_etag_comes_from_the_card
    with_store({"aiden" => AIDEN}) do |store|
      assert_equal ProTacts::Contact.etag_for(AIDEN), store.contact("aiden").etag
    end
  end

  # Nothing stores an etag beside a card, so there is no second copy to
  # fall out of step: change the bytes behind the store's back and the
  # etag follows them, because it was never anything but their hash.
  def test_an_etag_cannot_drift_from_its_card
    with_store({"aiden" => AIDEN}) do |store|
      refute_includes database(store)[:cards].columns, :etag

      updated = AIDEN.sub("Aiden", "Aiden Smith")
      database(store)[:cards].where(id: "aiden").update(vcard: updated)

      assert_equal ProTacts::Contact.etag_for(updated), store.contact("aiden").etag
    end
  end

  def test_an_id_that_could_not_be_served_is_refused
    with_store do |store|
      assert_raises(ArgumentError) { store.put("John Smith", AIDEN) }
      assert_empty store.contacts
    end
  end

  def test_a_card_survives_reopening_the_database
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir) / "contacts.db"
      ProTacts::Store.connect(path) { it.put("aiden", AIDEN) }

      ProTacts::Store.connect(path) do |store|
        assert_equal AIDEN, store.contact("aiden").vcard
      end
    end
  end

  # An id and a card off the wire are ASCII-8BIT, and Sequel writes
  # values into UTF-8 SQL: a card with an accent in it raises on the way
  # in unless the bytes are relabelled first.
  def test_binary_bytes_off_the_wire_are_stored_as_text
    accented = AIDEN.sub("Aiden", "Aiden Åberg")

    with_store do |store|
      store.put("aiden".b, accented.b)

      assert_equal accented, store.contact("aiden".b).vcard
      assert_equal accented, store.contact("aiden").vcard
      assert_equal Encoding::UTF_8, store.contact("aiden").vcard.encoding
      assert_equal ProTacts::Contact.etag_for(accented), store.contact("aiden").etag
    end
  end

  ## The collection's content tag

  def test_the_ctag_is_stable_across_reads
    with_store({"aiden" => AIDEN}) do |store|
      assert_equal store.ctag, store.ctag
    end
  end

  def test_the_ctag_moves_with_a_cards_content
    with_store({"aiden" => AIDEN}) do |store|
      before = store.ctag
      store.put("aiden", AIDEN.sub("Aiden", "Aiden Smith"))

      refute_equal before, store.ctag
    end
  end

  def test_the_ctag_moves_with_membership_both_ways
    with_store({"aiden" => AIDEN}) do |store|
      alone = store.ctag

      store.put("znorth", ZED)
      refute_equal alone, store.ctag

      store.delete("znorth")
      assert_equal alone, store.ctag
    end
  end

  ## Timestamps

  def test_a_stored_card_is_stamped
    with_store({"aiden" => AIDEN}) do |store|
      row = card_row(store, "aiden")

      assert_match TIMESTAMP, row.fetch(:created_at)
      assert_equal row.fetch(:created_at), row.fetch(:updated_at)
    end
  end

  def test_replacing_a_card_moves_updated_at_and_leaves_created_at
    with_store({"aiden" => AIDEN}) do |store|
      first = card_row(store, "aiden")
      sleep 0.002 # the stamp has millisecond resolution
      store.put("aiden", AIDEN.sub("Aiden", "Aiden Smith"))
      second = card_row(store, "aiden")

      assert_equal first.fetch(:created_at), second.fetch(:created_at)
      assert_operator second.fetch(:updated_at), :>, first.fetch(:updated_at)
    end
  end

  # A card written back unchanged is still a write, so it is still
  # touched: updated_at is when the store last accepted a card, not when
  # the bytes last differed.
  def test_storing_the_same_card_again_still_touches_it
    with_store({"aiden" => AIDEN}) do |store|
      before = card_row(store, "aiden").fetch(:updated_at)
      sleep 0.002
      store.put("aiden", AIDEN)

      assert_operator card_row(store, "aiden").fetch(:updated_at), :>, before
    end
  end

  def test_a_change_is_stamped_when_it_is_logged
    with_store({"aiden" => AIDEN}) do |store|
      assert_match TIMESTAMP, store.changes.last.created_at
    end
  end

  # Relabelling bytes is not converting them, so a card whose bytes are
  # not UTF-8 at all is refused rather than stored: better than serving
  # it back as `text/vcard; charset=utf-8` while it is no such thing.
  # Pinned here so that a later "fix" to Store#text has to be deliberate.
  def test_a_card_that_is_not_utf_8_is_refused
    with_store do |store|
      assert_raises(Sequel::DatabaseError) do
        store.put("bad", "BEGIN:VCARD\r\nFN:\xFF\xFE\r\nEND:VCARD\r\n".b)
      end

      assert_empty store.contacts
    end
  end

  ## The change log

  def test_a_put_records_the_card_and_its_etag
    with_store({"aiden" => AIDEN}) do |store|
      change = store.changes.last

      assert_equal "aiden", change.card_id
      assert_equal "put", change.action
      assert_equal ProTacts::Contact.etag_for(AIDEN), change.etag
    end
  end

  def test_every_write_is_logged_in_order
    with_store({"aiden" => AIDEN}) do |store|
      store.put("aiden", AIDEN.sub("Aiden", "Aiden Smith"))
      store.put("znorth", ZED)
      store.delete("aiden")

      assert_equal [%w[aiden put], %w[aiden put], %w[znorth put], %w[aiden delete]],
        store.changes.map { [it.card_id, it.action] }
      assert_equal store.changes.map { it.sequence }.sort, store.changes.map { it.sequence }
    end
  end

  def test_a_delete_leaves_a_tombstone_behind
    with_store({"aiden" => AIDEN}) do |store|
      assert store.delete("aiden")
      assert_nil store.contact("aiden")

      tombstone = store.changes.last
      assert_equal %w[aiden delete], [tombstone.card_id, tombstone.action]
      assert_nil tombstone.etag
    end
  end

  def test_deleting_nothing_logs_nothing
    with_store({"aiden" => AIDEN}) do |store|
      before = store.changes.length

      refute store.delete("nobody")
      assert_equal before, store.changes.length
    end
  end

  def test_changes_can_be_read_from_a_sequence_on
    with_store({"aiden" => AIDEN}) do |store|
      token = store.changes.last.sequence
      store.put("znorth", ZED)

      assert_equal %w[znorth], store.changes(after: token).map { it.card_id }
    end
  end

  # A sequence number is never reused, so a client holding an old token
  # cannot be handed changes numbered below ones it has already seen.
  def test_sequence_numbers_are_not_reused_after_a_delete
    with_store({"aiden" => AIDEN}) do |store|
      highest = store.changes.last.sequence
      store.delete("aiden")
      store.put("znorth", ZED)

      assert_operator store.changes.last.sequence, :>, highest
    end
  end

  # The whole reason the cards and the log are one database. Both tests
  # below fail part way through a write that has already put the card
  # row in: if the transaction were dropped, the card would survive and a
  # client's sync token would point at a history that never happened.
  #
  # Refusing a bad id does not test this, however it is named: Contact.for
  # raises before the transaction opens, so nothing was ever attempted.
  def test_a_write_that_fails_at_the_log_leaves_no_card
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir) / "contacts.db"

      FailingLog.connect(path) do |store|
        assert_raises(RuntimeError) { store.put("aiden", AIDEN) }
      end

      # Reopened, so this is the file talking and not a cache.
      ProTacts::Store.connect(path) do |store|
        assert_empty store.contacts
        assert_empty store.changes
      end
    end
  end

  # A put joins a transaction already open — the group fan-out this
  # design needs — so a rollback out there has to take the card, its log
  # entry and its index rows with it.
  def test_a_put_inside_a_failed_transaction_is_rolled_back_whole
    with_store do |store|
      assert_raises(RuntimeError) do
        database(store).transaction do
          store.put("aiden", AIDEN)
          raise "the fan-out failed"
        end
      end

      assert_empty store.contacts
      assert_empty store.changes
      assert_empty indexed_names(store, "aiden")
    end
  end

  ## The index

  def test_a_card_is_indexed_by_property
    with_store({"aiden" => AIDEN}) do |store|
      assert_equal %w[BEGIN VERSION FN UID END], indexed_names(store, "aiden")
    end
  end

  def test_parameters_are_indexed_with_their_property
    with_store({"aiden" => AIDEN.sub("FN:Aiden", "TEL;TYPE=work,voice:+1-555-1234\r\nFN:Aiden")}) do |store|
      assert_equal [%w[TYPE work], %w[TYPE voice]], indexed_parameters(store, "aiden", "TEL")
    end
  end

  def test_replacing_a_card_replaces_its_index_rows
    with_store({"aiden" => AIDEN}) do |store|
      store.put("aiden", AIDEN.sub("FN:Aiden\r\n", ""))

      assert_equal %w[BEGIN VERSION UID END], indexed_names(store, "aiden")
    end
  end

  def test_deleting_a_card_takes_its_index_rows_with_it
    with_store({"aiden" => AIDEN}) do |store|
      store.delete("aiden")

      assert_empty indexed_names(store, "aiden")
      assert_empty indexed_parameters(store, "aiden", "FN")
    end
  end

  # The index is derived and nothing else is authoritative in it, so
  # throwing it away and deriving it again from the cards alone has to
  # land in exactly the same place.
  def test_the_index_can_be_rebuilt_from_the_cards_alone
    with_store({"aiden" => AIDEN, "znorth" => ZED}) do |store|
      before = index_rows(store)
      refute_empty before

      wreck_the_index(store)
      refute_equal before, index_rows(store)

      assert_empty store.rebuild_index
      assert_equal before, index_rows(store)
    end
  end

  # Rows, not contacts, so that a rebuild which stamped updated_at would
  # be caught: the index is derived, and deriving it again is not a write
  # to the card it came from.
  def test_rebuilding_the_index_leaves_the_cards_and_the_log_alone
    with_store({"aiden" => AIDEN, "znorth" => ZED}) do |store|
      cards = database(store)[:cards].order(:id).all
      changes = store.changes

      sleep 0.002
      store.rebuild_index

      assert_equal cards, database(store)[:cards].order(:id).all
      assert_equal changes, store.changes
    end
  end

  ## Cards that will not parse

  # Fail open: the bytes are what gets served, so a card the parser
  # cannot read is still a contact. It just contributes nothing to the
  # index, and the rebuild names it.
  def test_an_unparseable_card_is_still_stored_and_served
    with_store({"broken" => "this is not a vCard\r\n"}) do |store|
      assert_equal "this is not a vCard\r\n", store.contact("broken").vcard
      assert_empty indexed_names(store, "broken")
    end
  end

  def test_rebuilding_names_the_cards_it_could_not_index
    with_store({"aiden" => AIDEN, "broken" => "this is not a vCard\r\n"}) do |store|
      assert_equal %w[broken], store.rebuild_index
      assert_equal %w[BEGIN VERSION FN UID END], indexed_names(store, "aiden")
    end
  end

  private

  # A store whose change-log write fails, after Store#put has already put
  # the card row in. Minitest 6 ships no stubbing, and a subclass says
  # what is being broken more plainly than a stub would.
  class FailingLog < ProTacts::Store
    private

    def record(card_id, action, etag)
      raise "the change log is unavailable"
    end
  end

  # The index is queried directly on purpose: it exists to be queried,
  # and a test that went back through the store would not show that it
  # can be.
  def database(store)
    store.instance_variable_get(:@database)
  end

  def card_row(store, id)
    database(store)[:cards].where(id:).sole
  end

  def indexed_names(store, card_id)
    database(store)[:card_properties].where(card_id:).order(:position).select_map(:name)
  end

  def indexed_parameters(store, card_id, name)
    parameter = Sequel[:card_parameters]

    database(store)[:card_parameters]
      .join(:card_properties, [:card_id, :position])
      .where(parameter[:card_id] => card_id, Sequel[:card_properties][:name] => name)
      .order(parameter[:rowid])
      .select_map([parameter[:name], parameter[:value]])
  end

  def index_rows(store)
    [
      database(store)[:card_properties].order(:card_id, :position).all,
      database(store)[:card_parameters].order(:card_id, :position, :name, :value).all,
    ]
  end

  def wreck_the_index(store)
    database(store)[:card_parameters].delete
    database(store)[:card_properties].update(value: "wrong")
  end
end
