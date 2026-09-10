require_relative "../test_helper"
require_relative "../photo_card"

require "pathname"
require "tmpdir"

require "sequel"

require "pro_tacts/store"
require "pro_tacts/vcard"

class StoreTest < Minitest::Test
  include Sentry::TestHelper
  include SentryMessages

  AIDEN = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nUID:aiden\r\nEND:VCARD\r\n"
  # The no-year birthday line as macOS writes it — the shape the
  # captured picture cards carry above their PHOTO trio.
  APPLE_NO_YEAR = "BDAY;X-APPLE-OMIT-YEAR=1604:1604-01-01" #: String
  # UTC ISO 8601 to the millisecond, which is what SQLite is asked for.
  TIMESTAMP = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/
  ZED = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Zed\r\nUID:znorth\r\nEND:VCARD\r\n"

  # A store on disk rather than in memory: WAL, the busy timeout, and
  # reopening a database are all part of what is under test.
  def with_store(cards = {})
    Dir.mktmpdir do |dir|
      ProTacts::Store.connect(Pathname.new(dir) / "contacts.db") do |store|
        cards.each do |id, card|
          store.put(id, vcard(card))
        end
        yield store
      end
    end
  end

  # A write takes the card, not its bytes: the store is handed the
  # reading its caller already made (Store#put), and the constants
  # here are the bytes a client would submit.
  def vcard(bytes) = ProTacts::VCard.new(bytes)

  # The store's reports land in the transport this pins for the test;
  # teardown clears it so nothing carries into the next one.
  def setup
    setup_sentry
  end

  def teardown
    teardown_sentry_test
  end

  ## Cards

  def test_a_stored_card_comes_back_byte_for_byte
    with_store({"aiden" => AIDEN}) do |store|
      assert_equal AIDEN, store.contact("aiden").vcard.to_s
    end
  end

  def test_contacts_are_listed_by_id
    with_store({"znorth" => ZED, "aiden" => AIDEN}) do |store|
      assert_equal %w[aiden znorth], store.contacts.map { it.id }
    end
  end

  def test_an_empty_store_lists_no_contacts
    with_store do
      assert_empty it.contacts
    end
  end

  def test_a_missing_contact_is_nil
    with_store do
      assert_nil it.contact("nobody")
    end
  end

  ## Pictures

  # The sizing case, byte for byte: a photo card is 338 KB — most of
  # it the PHOTO property's base64 folds — and the store's verbatim
  # design means every fold comes back out exactly as it arrived. The
  # memoji shape exercises the one physical line that runs 1,683
  # octets.
  def test_a_photo_card_round_trips_byte_for_byte
    with_store({}) do |store|
      store.put("ada", vcard(PhotoCard.photo("ada")))

      assert_equal PhotoCard.photo("ada"), store.contact("ada").vcard.to_s
    end
  end

  def test_a_memoji_card_round_trips_byte_for_byte
    with_store({}) do |store|
      store.put("ada", vcard(PhotoCard.memoji("ada")))

      assert_equal PhotoCard.memoji("ada"), store.contact("ada").vcard.to_s
    end
  end

  # The captured writes carry their BDAY above the picture trio, so
  # the birthday's move to the model and back is the one difference a
  # picture card sees: the PHOTO line, folds and all, is untouched.
  def test_a_photo_card_moves_only_its_birthday
    submitted = PhotoCard.photo("ada", extra: [APPLE_NO_YEAR])
    expected = PhotoCard.photo("ada").sub("END:VCARD\r\n", "#{APPLE_NO_YEAR}\r\nEND:VCARD\r\n")

    with_store({}) do |store|
      store.put("ada", vcard(submitted))

      assert_equal expected, store.contact("ada").vcard.to_s
    end
  end

  ## UIDs

  # The read behind the no-uid-conflict precondition (RFC 6352 section
  # 6.3.2.1).
  def test_the_card_holding_a_uid_is_found_by_it
    with_store({"aiden" => AIDEN}) do |store|
      assert_equal "aiden", store.card_id_with_uid("aiden")
    end
  end

  def test_a_uid_no_card_holds_finds_no_owner
    with_store({"aiden" => AIDEN}) do |store|
      assert_nil store.card_id_with_uid("znorth")
    end
  end

  # The lookup runs through the index, whose name column ignores case.
  def test_a_lowercase_uid_property_is_found
    lowercase = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nuid:aiden\r\nEND:VCARD\r\n"

    with_store({"aiden" => lowercase}) do |store|
      assert_equal "aiden", store.card_id_with_uid("aiden")
    end
  end

  def test_putting_the_same_id_replaces_the_card
    with_store({"aiden" => AIDEN}) do |store|
      updated = AIDEN.sub("Aiden", "Aiden Smith")
      store.put("aiden", vcard(updated))

      assert_equal [updated], store.contacts.map { it.vcard.to_s }
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
      assert_raises(ArgumentError) { store.put("John Smith", vcard(AIDEN)) }
      assert_empty store.contacts
    end
  end

  def test_a_card_survives_reopening_the_database
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir) / "contacts.db"
      ProTacts::Store.connect(path) do
        it.put("aiden", vcard(AIDEN))
      end

      ProTacts::Store.connect(path) do |store|
        assert_equal AIDEN, store.contact("aiden").vcard.to_s
      end
    end
  end

  # The store's contract is UTF-8, and the adapter enforces it: the
  # sqlite3 gem encodes every bound value to UTF-8, so a binary-flagged
  # string with a byte above 7 bits raises at the bind — loudly, at the
  # contract violation, rather than being quietly relabelled here. The
  # route is where Rack's binary becomes text (Web#write_card).
  def test_binary_bytes_above_ascii_raise_at_the_bind
    accented = AIDEN.sub("Aiden", "Aiden Åberg")

    with_store({"aiden" => AIDEN}) do |store|
      assert_raises(Encoding::UndefinedConversionError) do
        store.put("aiden".b, vcard(accented.b))
      end

      # Pure ASCII carries no such byte, so a binary-flagged id still
      # finds its row.
      assert_equal AIDEN, store.contact("aiden".b).vcard.to_s
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
      store.put("aiden", vcard(AIDEN.sub("Aiden", "Aiden Smith")))

      refute_equal before, store.ctag
    end
  end

  # The ctag is the change log's sequence, so it moves forward on a
  # removal too — it never returns to an earlier value, where the
  # membership hash this replaced did. A client that saw the earlier
  # value resyncs and finds every etag unchanged; the trade the
  # sequence makes for one indexed read and a monotonic answer.
  def test_the_ctag_moves_on_a_removal_and_never_returns
    with_store({"aiden" => AIDEN}) do |store|
      alone = store.ctag

      store.put("znorth", vcard(ZED))
      refute_equal alone, store.ctag

      store.delete("znorth")
      refute_equal alone, store.ctag
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
      store.put("aiden", vcard(AIDEN.sub("Aiden", "Aiden Smith")))
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
      store.put("aiden", vcard(AIDEN))

      assert_operator card_row(store, "aiden").fetch(:updated_at), :>, before
    end
  end

  def test_contacts_by_recency_orders_newest_first
    with_store({"aiden" => AIDEN}) do |store|
      sleep 0.002
      store.put("znorth", vcard(ZED))

      assert_equal %w[znorth aiden], store.contacts_by_recency.map { it.contact.id }
    end
  end

  def test_contacts_by_recency_carries_the_stamp
    with_store({"aiden" => AIDEN}) do |store|
      recent = store.contacts_by_recency.fetch(0)

      assert_match TIMESTAMP, recent.updated_at
      assert_equal card_row(store, "aiden").fetch(:updated_at), recent.updated_at
    end
  end

  def test_a_change_is_stamped_when_it_is_logged
    with_store({"aiden" => AIDEN}) do |store|
      assert_match TIMESTAMP, store.changes.last.created_at
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
      store.put("aiden", vcard(AIDEN.sub("Aiden", "Aiden Smith")))
      store.put("znorth", vcard(ZED))
      store.delete("aiden")

      assert_equal [%w[aiden put], %w[aiden put], %w[znorth put], %w[aiden delete]],
        store.changes.map { [it.card_id, it.action] }
      assert_equal store.changes.map { it.sequence }.sort, store.changes.map { it.sequence }
    end
  end

  ## The editor's write

  # rewrite is the store's own editor's path: the bytes land byte for
  # byte, the change-log entry carries the composed etag a client
  # would download, and the action names the side that wrote it — put
  # is a client's submission, edit is the admin's save. The birthday
  # passed beside the card is the model's whole new state
  # (docs/plans/2026-09-07-web-birthday-editor.md), so the caller
  # handing back the current one is the card-only save.
  def test_a_rewrite_stores_the_card_and_logs_the_composed_etag
    with_store({"aiden" => AIDEN_BORN}) do |store|
      edited = AIDEN.sub("FN:Aiden", "FN:Aiden Smith")

      contact = store.rewrite("aiden", vcard(edited), birthday: ProTacts::Birthday.new(year: 1985, month: 4, day: 12))

      assert_equal edited, card_row(store, "aiden").fetch(:vcard)
      composed = edited.sub("END:VCARD\r\n", "BDAY:1985-04-12\r\nEND:VCARD\r\n")
      assert_equal composed, contact.vcard.to_s
      assert_equal ProTacts::Contact.etag_for(composed), contact.etag
      change = store.changes.last
      assert_equal %w[aiden edit], [change.card_id, change.action]
      assert_equal ProTacts::Contact.etag_for(composed), change.etag
    end
  end

  # The hazard rewrite exists for: an editor's save carries no BDAY
  # line by construction, and put reads exactly that as a birthday the
  # client dropped — so running the save through put would delete the
  # model row and the contact's birthday with it. rewrite writes the
  # birthday it is handed, so the caller passing the current model —
  # what a card-only save does — keeps the row.
  def test_a_rewrite_writing_the_current_birthday_keeps_it
    with_store({"aiden" => AIDEN_BORN}) do |store|
      store.rewrite("aiden", vcard(AIDEN.sub("FN:Aiden", "FN:Aiden Smith")),
                    birthday: ProTacts::Birthday.new(year: 1985, month: 4, day: 12))

      assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12), birthday_row(store, "aiden")
      assert_includes store.contact("aiden").vcard.to_s, "BDAY:1985-04-12"
    end
  end

  # A birthday edit is a model write, and the served card moves with
  # it: the composed BDAY lands at the new value, the stored bytes do
  # not move at all, and the change-log entry carries the new composed
  # etag — a client's token has to see what a device would download.
  def test_a_rewrite_with_a_new_birthday_moves_the_served_card_only
    with_store({"aiden" => AIDEN_BORN}) do |store|
      stored = AIDEN_BORN.sub("BDAY:1985-04-12\r\n", "")

      contact = store.rewrite("aiden", vcard(stored), birthday: ProTacts::Birthday.new(month: 4, day: 12))

      assert_equal stored, card_row(store, "aiden").fetch(:vcard)
      assert_includes contact.vcard.to_s, "BDAY;X-APPLE-OMIT-YEAR=1604:1604-04-12\r\n"
      assert_equal ProTacts::Birthday.new(month: 4, day: 12), birthday_row(store, "aiden")
      assert_equal contact.etag, store.changes.last.etag
    end
  end

  # Nil is the row's blank-equals-absent: the model row goes, and the
  # composed card with it.
  def test_a_rewrite_with_no_birthday_deletes_the_row
    with_store({"aiden" => AIDEN_BORN}) do |store|
      stored = AIDEN_BORN.sub("BDAY:1985-04-12\r\n", "")

      contact = store.rewrite("aiden", vcard(stored), birthday: nil)

      assert_nil birthday_row(store, "aiden")
      refute_includes contact.vcard.to_s, "BDAY"
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
      store.put("znorth", vcard(ZED))

      assert_equal %w[znorth], store.changes(after: token).map { it.card_id }
    end
  end

  def test_one_cards_changes_come_back_newest_first
    with_store({"aiden" => AIDEN}) do |store|
      store.put("znorth", vcard(ZED))
      store.delete("aiden")

      log = store.changes_of("aiden")
      assert_equal %w[delete put], log.map { it.action }
      assert_operator log.first.sequence, :>, log.last.sequence
    end
  end

  # The tombstone outlives the card, which is the point of a card id
  # rather than a foreign key — and the history stays readable for an
  # id the cards table no longer has a row for.
  def test_a_deleted_cards_changes_still_read
    with_store({"aiden" => AIDEN}) do |store|
      store.delete("aiden")

      assert_equal %w[delete put], store.changes_of("aiden").map { it.action }
    end
  end

  def test_an_unknown_cards_changes_are_empty
    with_store({"aiden" => AIDEN}) do |store|
      assert_empty store.changes_of("nobody")
    end
  end

  # A sequence number is never reused, so a client holding an old token
  # cannot be handed changes numbered below ones it has already seen.
  def test_sequence_numbers_are_not_reused_after_a_delete
    with_store({"aiden" => AIDEN}) do |store|
      highest = store.changes.last.sequence
      store.delete("aiden")
      store.put("znorth", vcard(ZED))

      assert_operator store.changes.last.sequence, :>, highest
    end
  end

  # The whole reason the cards and the log are one database. Both tests
  # below fail part way through a write that has already put the card
  # row in: if the transaction were dropped, the card would survive and a
  # client's sync token would point at a history that never happened.
  #
  # Refusing a bad id does not test this, however it is named:
  # Contact's constructor raises before the transaction opens, so
  # nothing was ever attempted.
  def test_a_write_that_fails_at_the_log_leaves_no_card
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir) / "contacts.db"

      FailingLog.connect(path) do |store|
        assert_raises(RuntimeError) { store.put("aiden", vcard(AIDEN)) }
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
          store.put("aiden", vcard(AIDEN))
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
      store.put("aiden", vcard(AIDEN.sub("FN:Aiden\r\n", "")))

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

      store.rebuild_index

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
  # cannot read is still a contact. Its unreadable lines contribute
  # nothing to the index and cost the index nothing else.
  def test_an_unparseable_card_is_still_stored_and_served
    with_store({"broken" => "this is not a vCard\r\n"}) do |store|
      assert_equal "this is not a vCard\r\n", store.contact("broken").vcard.to_s
      assert_empty indexed_names(store, "broken")
    end
  end

  # The collection's half of fail open: a card the parser cannot read
  # costs the listing nothing, every other contact serves beside it,
  # and the ctag moves on its arrival — the broken card is served from
  # its bytes like any other, so the tag counts it.
  def test_every_other_contact_serves_beside_one_unparseable_card
    with_store({"aiden" => AIDEN, "znorth" => ZED}) do |store|
      good_cards = store.ctag
      store.put("broken", vcard("this is not a vCard\r\n"))

      assert_equal %w[aiden broken znorth], store.contacts.map { it.id }
      assert_equal AIDEN, store.contact("aiden").vcard.to_s
      assert_equal ZED, store.contact("znorth").vcard.to_s
      refute_equal good_cards, store.ctag
    end
  end

  # The index is what this server understood, not an all-or-nothing
  # verdict on the card.
  def test_a_card_is_indexed_by_the_lines_that_read
    unreadable = AIDEN.sub("FN:Aiden\r\n", "FN:Aiden\r\nTEL;HOME:+1-555-1234\r\n")
    with_store({"aiden" => unreadable}) do |store|
      assert_equal %w[BEGIN VERSION FN UID END], indexed_names(store, "aiden")
      assert_equal unreadable, store.contact("aiden").vcard.to_s
    end
  end

  ## Birthdays

  AIDEN_BORN = AIDEN.sub("FN:Aiden\r\n", "FN:Aiden\r\nBDAY:1985-04-12\r\n")

  # The stored card carries no BDAY — a partial date has no vCard 3.0
  # spelling — and every read composes the birthday back in, so the
  # served card is the submitted one with the line back where compose
  # puts it.
  def test_a_birthday_is_stored_beside_the_card_and_served_within_it
    with_store({"aiden" => AIDEN_BORN}) do |store|
      assert_equal AIDEN, card_row(store, "aiden").fetch(:vcard)
      assert_equal AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04-12\r\nEND:VCARD\r\n"), store.contact("aiden").vcard.to_s
    end
  end

  # The composed card is what an etag describes, on a read and in the
  # change log alike, so a client's If-Match and its sync token both
  # talk about the card it downloads.
  def test_the_etag_and_the_log_describe_the_composed_card
    with_store({"aiden" => AIDEN_BORN}) do |store|
      composed = AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04-12\r\nEND:VCARD\r\n")

      assert_equal ProTacts::Contact.etag_for(composed), store.contact("aiden").etag
      assert_equal ProTacts::Contact.etag_for(composed), store.changes.last.etag
    end
  end

  # The ctag follows the composed card too: a birthday moved is a
  # change a client must see, even when the stored bytes did not move.
  def test_the_ctag_moves_with_a_birthday_alone
    with_store({"aiden" => AIDEN}) do |store|
      before = store.ctag
      store.put("aiden", vcard(AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04-12\r\nEND:VCARD\r\n")))

      refute_equal before, store.ctag
    end
  end

  def test_an_apple_no_year_birthday_round_trips
    with_store({"aiden" => AIDEN.sub("END:VCARD\r\n", "BDAY;X-APPLE-OMIT-YEAR=1604:1604-04-12\r\nEND:VCARD\r\n")}) do |store|
      assert_equal ProTacts::Birthday.new(month: 4, day: 12), birthday_row(store, "aiden")
    end
  end

  # A submitted card with no BDAY deletes the birthday — the client
  # was served one and sent its card back without it, which on a
  # read-modify-write client is the user removing it.
  def test_a_card_put_back_without_its_served_birthday_loses_it
    with_store({"aiden" => AIDEN_BORN}) do |store|
      store.put("aiden", vcard(AIDEN))

      assert_nil birthday_row(store, "aiden")
      assert_equal AIDEN, store.contact("aiden").vcard.to_s
    end
  end

  # A birthday no client can see — year alone, month alone, day alone,
  # year and month — survives a round trip the client never saw a
  # birthday in. Planted directly, because no writer produces one yet.
  def test_a_birthday_no_client_can_see_survives_a_card_without_one
    with_store({"aiden" => AIDEN}) do |store|
      database(store)[:birthdays].insert(card_id: "aiden", year: 1985)

      store.put("aiden", vcard(AIDEN.sub("FN:Aiden", "FN:Aiden Smith")))

      assert_equal ProTacts::Birthday.new(year: 1985), birthday_row(store, "aiden")
      assert_equal AIDEN.sub("FN:Aiden", "FN:Aiden Smith"), store.contact("aiden").vcard.to_s
    end
  end

  # The card's own line speaks for itself, and nothing composes a
  # second one beside it. A fold travels with its line, byte for byte.
  def test_an_unmodeled_bday_stays_in_the_card_and_empties_the_model
    ["BDAY:--0412", "BDAY:1985-\r\n 04\r\n", "BDAY:1985-04-12\r\nBDAY:1986-04-12\r\n"].each do |bday|
      unmodeled = AIDEN.sub("END:VCARD\r\n", "#{bday}END:VCARD\r\n")

      with_store({"aiden" => AIDEN_BORN}) do |store|
        store.put("aiden", vcard(unmodeled))

        assert_equal unmodeled, store.contact("aiden").vcard.to_s, bday
        assert_nil birthday_row(store, "aiden"), bday
      end
    end
  end

  # A bare CR packs two content lines into one physical line, a shape
  # the parser is built to assume macOS never sends, so the line is
  # never read. The store says nothing about it: a value it never read
  # is not a value it failed to recognize, and reporting it as an odd
  # BDAY would send anyone reading the message looking in the wrong
  # place. WebTest holds the report worth making, at the arrival.
  def test_a_bday_sharing_its_line_arrives_whole_and_unreported
    shared = AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04-12\rNOTE:b\r\nEND:VCARD\r\n")

    with_store({"aiden" => AIDEN_BORN}) do |store|
      store.put("aiden", vcard(shared))
      messages = sentry_messages

      assert_equal shared, store.contact("aiden").vcard.to_s
      assert_nil birthday_row(store, "aiden")
      assert_empty messages
    end
  end

  # macOS Contacts drops the lines it cannot render from every card it
  # writes, so a rewrite that omits the BDAY carries them across rather
  # than reading the absence as a deletion (docs/macos-contacts.md, "A
  # birthday the client cannot render is dropped from the card").
  def test_a_birthday_no_client_renders_survives_a_rewrite_that_drops_it
    ["BDAY:1985-04", "BDAY:1985", "BDAY:--04", "BDAY:---12"].each do |line|
      with_store({"aiden" => AIDEN.sub("END:VCARD\r\n", "#{line}\r\nEND:VCARD\r\n")}) do |store|
        edited = AIDEN.sub("FN:Aiden", "FN:Aiden Smith")

        store.put("aiden", vcard(edited))

        assert_equal edited.sub("END:VCARD\r\n", "#{line}\r\nEND:VCARD\r\n"), store.contact("aiden").vcard.to_s, line
        assert_nil birthday_row(store, "aiden"), line
      end
    end
  end

  # The divider is the shape, not the spelling: macOS renders --0412,
  # so a rewrite without it has removed a birthday the client could
  # see, and the deletion is honored. Honoring it is what keeps these
  # deletable at all.
  def test_a_birthday_a_client_renders_is_deleted_by_a_rewrite_without_it
    with_store({"aiden" => AIDEN.sub("END:VCARD\r\n", "BDAY:--0412\r\nEND:VCARD\r\n")}) do |store|
      store.put("aiden", vcard(AIDEN))

      assert_equal AIDEN, store.contact("aiden").vcard.to_s
      assert_nil birthday_row(store, "aiden")
    end
  end

  # The rewrite's half of the same rule: a shared line is not carried
  # (carrying it would carry its fellow bytes too), so dropping it is
  # reported rather than silent.
  def test_a_rewrite_dropping_a_shared_bday_line_is_reported
    shared = AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04\rNOTE:b\r\nEND:VCARD\r\n")
    edited = AIDEN.sub("FN:Aiden", "FN:Aiden Smith")

    with_store({"aiden" => shared}) do |store|
      store.put("aiden", vcard(edited))
      messages = sentry_messages

      assert_equal edited, store.contact("aiden").vcard.to_s
      assert_equal 1, messages.length
    end
  end

  # A submission carrying any BDAY replaces what was there, carried
  # line included: PUT is a whole-card replace, not a merge.
  def test_a_submitted_birthday_replaces_the_carried_line
    with_store({"aiden" => AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04\r\nEND:VCARD\r\n")}) do |store|
      born = AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04-12\r\nEND:VCARD\r\n")

      store.put("aiden", vcard(born))

      assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12), birthday_row(store, "aiden")
      assert_equal born, store.contact("aiden").vcard.to_s
    end
  end

  # The loss report, the rewrite's half of the arrival one: a stored
  # BDAY no client renders and no whitelist recognizes is about to be
  # dropped, and nobody would know.
  def test_a_rewrite_dropping_an_unrecognized_bday_is_reported
    with_store({"aiden" => AIDEN.sub("END:VCARD\r\n", "BDAY:1985-13\r\nEND:VCARD\r\n")}) do |store|
      # The seed's own arrival report is not this test's subject.
      clear_sentry_events
      store.put("aiden", vcard(AIDEN.sub("FN:Aiden", "FN:Aiden Smith")))
      messages = sentry_messages

      assert_equal 1, messages.length
      assert_match(/BDAY/, messages.fetch(0))
    end
  end

  # A rewrite's quiet cases: a carried line survives (asserted above),
  # a rendered one was deleted by a user who could see it, and a card
  # with no BDAY at all has nothing to say.
  def test_a_rewrite_over_known_bdays_stays_quiet
    ["BDAY:--0412", "BDAY:1985-04"].each do |line|
      with_store({"aiden" => AIDEN.sub("END:VCARD\r\n", "#{line}\r\nEND:VCARD\r\n")}) do |store|
        store.put("aiden", vcard(AIDEN.sub("FN:Aiden", "FN:Aiden Smith")))

        assert_empty sentry_messages, line
      end
    end
  end

  # The arrival report: a submitted BDAY this server can neither model,
  # recognize as rendered, nor recognize as carried is unexpected input,
  # and storing it verbatim would be the last anyone heard of it.
  # Known forms — the modeled spellings, the reduced values macOS
  # reads, the carried shapes — stay quiet.
  def test_an_unrecognized_bday_arriving_is_reported
    ["BDAY:1985-13", "BDAY:--0432", "BDAY:19850412", "BDAY:1985-4"].each do |line|
      with_store({}) do |store|
        clear_sentry_events
        store.put("aiden", vcard(AIDEN.sub("END:VCARD\r\n", "#{line}\r\nEND:VCARD\r\n")))

        assert_equal 1, sentry_messages.length, line
      end
    end
  end

  def test_a_bday_the_server_knows_arrives_quietly
    ["BDAY:1985-04-12", "BDAY:1985-04-12T23:10:00Z", "BDAY;X-APPLE-OMIT-YEAR=1604:1604-04-12",
      "BDAY:--0412", "BDAY:--04-12", "BDAY:1985-04", "BDAY:1985"].each do |line|
      with_store({}) do |store|
        store.put("aiden", vcard(AIDEN.sub("END:VCARD\r\n", "#{line}\r\nEND:VCARD\r\n")))

        assert_empty sentry_messages, line
      end
    end
  end

  ## The change log
  def test_a_stored_card_is_never_indexed_with_a_bday
    with_store({"aiden" => AIDEN_BORN}) do |store|
      assert_equal %w[BEGIN VERSION FN UID END], indexed_names(store, "aiden")
    end
  end

  def test_deleting_a_card_takes_its_birthday_with_it
    with_store({"aiden" => AIDEN_BORN}) do |store|
      store.delete("aiden")

      assert_empty database(store)[:birthdays].all
    end
  end

  ## Upcoming birthdays

  NO_YEAR = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:No Year\r\n" \
    "BDAY;X-APPLE-OMIT-YEAR=1604:1604-06-15\r\nUID:noyear\r\nEND:VCARD\r\n"

  # Arrival order is the coming year's, not the calendar's: a
  # birthday already passed this year wraps onto next year and sorts
  # after one still ahead, and one already here today is first.
  def test_upcoming_birthdays_arrive_in_order_across_the_year_wrap
    september = Date.new(2026, 9, 3)
    ahead = AIDEN.sub("FN:Aiden\r\n", "FN:Aiden\r\nBDAY:1985-09-04\r\n")
    passed = ZED.sub("FN:Zed\r\n", "FN:Zed\r\nBDAY:1990-03-15\r\n")
    today = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Today\r\nBDAY:2000-09-03\r\nUID:today\r\nEND:VCARD\r\n"

    with_store({"aiden" => ahead, "znorth" => passed, "today" => today}) do |store|
      upcoming = store.upcoming_birthdays(10, today: september)

      assert_equal %w[today aiden znorth], upcoming.map { it.contact.id }
      assert_equal Date.new(2026, 9, 3), upcoming.fetch(0).occurs_on
      assert_equal Date.new(2026, 9, 4), upcoming.fetch(1).occurs_on
      assert_equal Date.new(2027, 3, 15), upcoming.fetch(2).occurs_on
    end
  end

  def test_upcoming_birthdays_take_the_first_n
    september = Date.new(2026, 9, 3)
    cards = (1..3).to_h { |n|
      ["c#{n}", "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Contact #{n}\r\nBDAY:1990-09-0#{n + 4}\r\nUID:c#{n}\r\nEND:VCARD\r\n"]
    }

    with_store(cards) do |store|
      assert_equal %w[c1 c2], store.upcoming_birthdays(2, today: september).map { it.contact.id }
    end
  end

  # The age is the view's question, not the query's.
  def test_a_birthday_without_a_year_is_upcoming
    september = Date.new(2026, 9, 3)

    with_store({"noyear" => NO_YEAR}) do |store|
      upcoming = store.upcoming_birthdays(10, today: september)

      assert_equal 1, upcoming.length
      assert_equal "noyear", upcoming.fetch(0).contact.id
      assert_equal Date.new(2027, 6, 15), upcoming.fetch(0).occurs_on
    end
  end

  # Planted directly, because no writer produces one yet.
  def test_birthdays_on_no_calendar_day_are_left_out
    september = Date.new(2026, 9, 3)

    with_store({"aiden" => AIDEN_BORN, "noyear" => NO_YEAR, "znorth" => ZED}) do |store|
      database(store)[:birthdays].where(card_id: "noyear").update(year: 1990, month: 6, day: nil)
      database(store)[:birthdays].insert(card_id: "znorth", year: 1990)

      assert_equal %w[aiden], store.upcoming_birthdays(10, today: september).map { it.contact.id }
    end
  end

  # Well-shaped but calendar-nonsense — February 30 — lands on the
  # month's last day for ordering, the same value Format.birthday
  # rescues to a raw display of.
  def test_a_day_the_month_does_not_have_orders_on_the_months_last_day
    september = Date.new(2026, 9, 3)
    nonsense = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Nonsense\r\nBDAY:1980-02-30\r\nUID:nonsense\r\nEND:VCARD\r\n"

    with_store({"nonsense" => nonsense, "noyear" => NO_YEAR}) do |store|
      upcoming = store.upcoming_birthdays(10, today: september)

      assert_equal Date.new(2027, 2, 28), upcoming.fetch(0).occurs_on
    end
  end

  # The transaction the whole design turns on, now with a third piece:
  # a birthday must not survive a write whose log entry failed.
  def test_a_failed_birthday_write_leaves_no_birthday
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir) / "contacts.db"

      FailingLog.connect(path) do |store|
        assert_raises(RuntimeError) { store.put("aiden", vcard(AIDEN_BORN)) }
      end

      ProTacts::Store.connect(path) do |store|
        assert_empty store.contacts
        assert_empty database(store)[:birthdays].all
      end
    end
  end

  ## Groups

  HOUSEHOLD_ADDRESS = "ADR;TYPE=home:;;7 Calculus Close;London;England;NW1 1AB;United Kingdom" #: String
  HOUSEHOLD_NOTE = "NOTE:Gate code 1854." #: String

  # A group's own row is Store#create_group's, which is what mints the
  # id; its properties and its members have no write path yet —
  # authoring is the admin UI's task — so those land the way the
  # fixture seeder's do, straight through the store's own database.
  # Hands back the id, which is the only way a caller learns it.
  def add_group(store, members:, lines:, name: nil)
    db = database(store)
    id = store.create_group(name:)
    lines.each.with_index do |line, position|
      db[:group_properties].insert(group_id: id, position:, line:)
    end
    members.each do |card_id|
      db[:group_members].insert(group_id: id, card_id:)
    end
    id
  end

  # A member's served card is the stored one with the group's lines
  # composed in, and the birthday composed after them — every read,
  # single or listed, hands out the same composed card.
  def test_a_member_serves_the_group_lines_composed_in
    born = AIDEN.sub("FN:Aiden\r\n", "FN:Aiden\r\nBDAY:1985-12-10\r\n")
    composed = AIDEN.sub(
      "END:VCARD\r\n",
      "#{HOUSEHOLD_ADDRESS}\r\n#{HOUSEHOLD_NOTE}\r\nBDAY:1985-12-10\r\nEND:VCARD\r\n",
    )

    with_store({"aiden" => born, "znorth" => ZED}) do |store|
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS, HOUSEHOLD_NOTE])

      assert_equal composed, store.contact("aiden").vcard.to_s
      assert_equal composed, store.contacts.find { it.id == "aiden" }.vcard.to_s
      assert_equal composed, store.contacts_by_recency.find { it.contact.id == "aiden" }.contact.vcard.to_s
    end
  end

  # A contact in no group serves the stored bytes with the etag it
  # always had — the byte-identity the whole fixture replay stands on.
  def test_a_contact_in_no_group_serves_unchanged_bytes_and_etag
    with_store({"aiden" => AIDEN, "znorth" => ZED}) do |store|
      before = store.contact("aiden")
      add_group(store, members: ["znorth"], lines: [HOUSEHOLD_ADDRESS])

      after = store.contact("aiden")
      assert_equal AIDEN, after.vcard.to_s
      assert_equal before.etag, after.etag
    end
  end

  # Membership is the only lever: a contact that leaves the group
  # serves its own bytes again, at the etag it had before any of the
  # group's lines reached it.
  def test_leaving_a_group_restores_the_stored_bytes
    with_store({"aiden" => AIDEN}) do |store|
      before = store.contact("aiden").etag
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])
      refute_equal before, store.contact("aiden").etag

      database(store)[:group_members].where(card_id: "aiden").delete
      assert_equal AIDEN, store.contact("aiden").vcard.to_s
      assert_equal before, store.contact("aiden").etag
    end
  end

  # Two groups' lines compose in group-id order, then position — the
  # order is a fact of the schema, not of whichever join SQLite
  # returns first, so the composed bytes never move between reads. The
  # ids are minted rather than chosen, so the expectation is sorted by
  # them: which group leads is the ids' business, that the id decides
  # it rather than the creation order is this test's.
  def test_two_groups_compose_in_a_fixed_order
    with_store({"aiden" => AIDEN}) do |store|
      lent = {
        add_group(store, members: ["aiden"], lines: [HOUSEHOLD_NOTE]) => HOUSEHOLD_NOTE,
        add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS]) => HOUSEHOLD_ADDRESS,
      }

      first, second = lent.sort.map { it.last }
      composed = AIDEN.sub("END:VCARD\r\n", "#{first}\r\n#{second}\r\nEND:VCARD\r\n")
      assert_equal composed, store.contact("aiden").vcard.to_s
    end
  end

  # The index projects the stored cards, and no stored card carries an
  # inherited line: the group's address is in the served card and in
  # no index row, and rebuilding the index leaves it that way.
  def test_the_index_holds_nothing_the_group_composes_in
    with_store({"aiden" => AIDEN}) do |store|
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])

      assert_includes store.contact("aiden").vcard.to_s, HOUSEHOLD_ADDRESS
      assert_includes indexed_names(store, "aiden"), "FN"
      refute_includes indexed_names(store, "aiden"), "ADR"

      store.rebuild_index
      refute_includes indexed_names(store, "aiden"), "ADR"
    end
  end

  # A PUT and an editor's save both hand back the composed contact —
  # the etag each records in the change log is the composed card's, so
  # a client's token describes what there is to download. The first
  # entry is with_store's own seed put, logged before the group existed.
  def test_writes_log_the_composed_etag_for_a_member
    with_store({"aiden" => AIDEN}) do |store|
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])

      put = store.put("aiden", vcard(AIDEN))
      edit = store.rewrite("aiden", vcard(AIDEN), birthday: nil)
      logged = database(store)[:changes].where(card_id: "aiden").order(:sequence).all

      assert_equal [put.etag, edit.etag], logged.last(2).map { it[:etag] }
      assert_includes put.vcard.to_s, HOUSEHOLD_ADDRESS
    end
  end

  # Every inherited line carries the name of the group lending it, on
  # the single read and on the listing read that composes a whole
  # collection — a screen marks a row as the household's from either.
  def test_an_inherited_line_carries_its_groups_name
    with_store({"aiden" => AIDEN}) do |store|
      add_group(store, name: "Household", members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])

      listed = store.contacts.find { it.id == "aiden" }
      [store.contact("aiden"), listed].each do |contact|
        assert_equal "Household", contact.group_of(contact.addresses.fetch(0).line)
      end
    end
  end

  # A group with no name lends its lines under its id, on both reads —
  # a mark that says which group a row came from, where the name would
  # otherwise leave the row marked with nothing at all.
  def test_a_nameless_groups_lines_are_marked_with_its_id
    with_store({"aiden" => AIDEN}) do |store|
      id = add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])

      listed = store.contacts.find { it.id == "aiden" }
      [store.contact("aiden"), listed].each do |contact|
        assert_equal id, contact.group_of(contact.addresses.fetch(0).line)
      end
    end
  end

  # Membership is a read of its own: every group a contact is in,
  # under the label a screen shows it by — the name, or the id where
  # there is no name — ordered by id so a rename never moves a tag. A
  # group that lends nothing is a membership like any other; it is the
  # inherited reads, not this one, that have nothing of it to carry.
  def test_the_groups_a_contact_is_in_are_read_with_their_labels
    with_store({"aiden" => AIDEN, "znorth" => ZED}) do |store|
      named = add_group(store, name: "Booles", members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])
      nameless = add_group(store, members: ["aiden"], lines: [])
      add_group(store, name: "Neighbours", members: [], lines: [HOUSEHOLD_NOTE])

      expected = {named => "Booles", nameless => nameless}.sort.map { it.last }
      assert_equal expected, store.groups_of("aiden")
      assert_empty store.groups_of("znorth")
    end
  end

  # The schema is the only gate on what a group may hold until
  # authoring exists, so what it admits is worth pinning: an address
  # or a note, bare or parameterized, in whatever case the author
  # spelled the name. Everything else is refused — a phone or an email
  # reaches a person rather than a household, and a grouped ADR is half
  # of a labeled property whose other half no group may hold.
  def test_a_group_holds_only_addresses_and_notes
    with_store({"aiden" => AIDEN}) do |store|
      properties = database(store)[:group_properties]
      group_id = store.create_group(name: "Household")

      admitted = [HOUSEHOLD_ADDRESS, HOUSEHOLD_NOTE, "ADR:;;1 Long Road;;;;", "note:lowercase is the same name"]
      admitted.each.with_index do |line, position|
        properties.insert(group_id:, position:, line:)
      end
      assert_equal admitted, properties.order(:position).map { it.fetch(:line) }

      ["TEL;TYPE=home:+44 20 5555 0100", "EMAIL:boole@example.com", "item1.ADR:;;1 Long Road;;;;"].each do |line|
        assert_raises(Sequel::ConstraintViolation) do
          properties.insert(group_id:, position: admitted.size, line:)
        end
      end
    end
  end

  # An id is minted, never chosen, in the shape jj spells a change id:
  # four letters from k to z, drawn independently, so that two creates
  # in a row are two groups.
  def test_a_created_group_takes_a_change_id
    with_store do |store|
      ids = Array.new(8) { store.create_group }

      ids.each { assert_match(/\A[k-z]{4}\z/, it) }
      assert_equal ids.size, ids.uniq.size
    end
  end

  # The schema is the gate on the id's shape, the way it is the gate on
  # what a group may hold: nothing else stops a hand-written row from
  # taking a word, a hash, or a change id's letters in the wrong case.
  def test_the_schema_refuses_an_id_that_is_not_a_change_id
    with_store do |store|
      ["household", "abcd", "kxs", "kxsvv", "KXSV", "kx s"].each do |id|
        assert_raises(Sequel::ConstraintViolation) do
          database(store)[:groups].insert(id:, name: "Household")
        end
      end
    end
  end

  # A group may have no name — NULL, the one spelling of it. The empty
  # string is the other spelling the column would otherwise admit, and
  # it renders as a mark with nothing in it, so the schema refuses it.
  def test_a_group_may_be_nameless_but_not_named_nothing
    with_store do |store|
      id = store.create_group

      assert_nil database(store)[:groups].where(id:).sole.fetch(:name)
      assert_raises(Sequel::ConstraintViolation) { store.create_group(name: "") }
    end
  end

  # The fourth action value exists for the fan-out a group edit will
  # write; nothing writes it yet, and this pins that the log can hold
  # one when it does.
  def test_the_change_log_admits_the_group_action
    with_store({"aiden" => AIDEN}) do |store|
      database(store)[:changes].insert(card_id: "aiden", action: "group", etag: "\"x\"")

      assert_equal "group", store.changes.last.action
    end
  end

  ## Subtracting what a group lends

  # The member's own address, deliberately unlike the group's so a
  # stored line and a lent one are told apart by their bytes.
  OWN_ADDRESS = "ADR:;;1 Long Road;;;;" #: String
  # The group's address as a client sends it back changed — one digit,
  # so nothing but the value moved.
  EDITED_ADDRESS = HOUSEHOLD_ADDRESS.sub("7 Calculus", "8 Calculus") #: String
  # The group's lines as macOS returns them on a card whose address and
  # note nobody edited: the parameter name lowercased, its value
  # uppercased, `pref` filled in, an unmodeled parameter dropped, and
  # every value byte-identical (docs/macos-contacts.md, "The client
  # rewrites every card it touches" and "An annotation survives only on
  # its own line").
  RESERIALIZED_ADDRESS = HOUSEHOLD_ADDRESS.sub("ADR;TYPE=home:", "ADR;type=HOME;type=pref:") #: String
  # The same address lent with no type on it, which is a shape the
  # round trip leaves alone.
  UNTYPED_ADDRESS = HOUSEHOLD_ADDRESS.sub("ADR;TYPE=home:", "ADR:") #: String
  TAGGED_NOTE = HOUSEHOLD_NOTE.sub("NOTE:", "NOTE;LANGUAGE=en:") #: String

  # The round trip the whole composition rests on: a member PUTs back
  # what it downloaded, and what is stored is the card it was composed
  # from — the group's lines in the served card, in the index nowhere
  # (docs/plans/2026-08-24-vcard-storage-and-groups.md).
  def test_a_members_put_of_its_served_card_stores_what_it_started_with
    with_store({"aiden" => AIDEN}) do |store|
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS, HOUSEHOLD_NOTE])
      served = store.contact("aiden").vcard.to_s

      contact = store.put("aiden", vcard(served))

      assert_equal AIDEN, card_row(store, "aiden").fetch(:vcard)
      assert_equal served, contact.vcard.to_s
      refute_includes indexed_names(store, "aiden"), "ADR"
    end
  end

  # Both subtractions in one write, and the composition puts them back
  # in the order it always does: the group's lines, then the birthday.
  def test_a_put_subtracts_the_birthday_and_the_lent_lines_together
    born = AIDEN.sub("FN:Aiden\r\n", "FN:Aiden\r\nBDAY:1985-12-10\r\n")

    with_store({"aiden" => born}) do |store|
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])
      served = store.contact("aiden").vcard.to_s

      store.put("aiden", vcard(served))

      assert_equal AIDEN, card_row(store, "aiden").fetch(:vcard)
      assert_equal served, store.contact("aiden").vcard.to_s
    end
  end

  # A member's own line of the name its group lends keeps its place in
  # the card: the subtraction takes the lent copy and moves nothing
  # else, which is what lets the round trip hold for a member that
  # carries an address of its own.
  def test_a_members_own_line_survives_the_subtraction_in_place
    own = AIDEN.sub("FN:Aiden\r\n", "#{OWN_ADDRESS}\r\nFN:Aiden\r\n")

    with_store({"aiden" => own}) do |store|
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])
      served = store.contact("aiden").vcard.to_s

      store.put("aiden", vcard(served))

      assert_equal own, card_row(store, "aiden").fetch(:vcard)
      assert_equal served, store.contact("aiden").vcard.to_s
    end
  end

  # An edit to a shared value is detected and left where it landed:
  # the member's card keeps it, the group keeps its own, and the
  # member serves both until the propagation task takes the edit to
  # the group (the plan's "Edits propagate to the group").
  def test_an_edited_lent_line_stays_in_the_members_own_card
    with_store({"aiden" => AIDEN}) do |store|
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])
      served = store.contact("aiden").vcard.to_s

      store.put("aiden", vcard(served.sub(HOUSEHOLD_ADDRESS, EDITED_ADDRESS)))

      assert_includes card_row(store, "aiden").fetch(:vcard), EDITED_ADDRESS
      composed = store.contact("aiden").vcard.to_s
      assert_includes composed, EDITED_ADDRESS
      assert_includes composed, HOUSEHOLD_ADDRESS
      assert_empty sentry_messages
    end
  end

  # The round trip as a real client makes it: macOS re-serializes every
  # line of every card it touches, so the group's address comes back
  # spelled its way on an address nobody edited. Matching bytes would
  # call that an edit and materialize the group's line into the
  # member's own card, which is what the composition exists to prevent.
  def test_a_reserialized_lent_line_is_still_the_groups
    with_store({"aiden" => AIDEN}) do |store|
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])
      served = store.contact("aiden").vcard.to_s

      store.put("aiden", vcard(served.sub(HOUSEHOLD_ADDRESS, RESERIALIZED_ADDRESS)))

      assert_equal AIDEN, card_row(store, "aiden").fetch(:vcard)
      assert_equal served, store.contact("aiden").vcard.to_s
      assert_empty sentry_messages
    end
  end

  # The same for a note, whose re-serialization is a parameter the
  # client does not model going missing.
  def test_a_lent_note_stripped_of_its_parameter_is_still_the_groups
    with_store({"aiden" => AIDEN}) do |store|
      add_group(store, members: ["aiden"], lines: [TAGGED_NOTE])
      served = store.contact("aiden").vcard.to_s

      store.put("aiden", vcard(served.sub(TAGGED_NOTE, HOUSEHOLD_NOTE)))

      assert_equal AIDEN, card_row(store, "aiden").fetch(:vcard)
      assert_equal served, store.contact("aiden").vcard.to_s
      assert_empty sentry_messages
    end
  end

  # Relabelling a shared address is an edit to the shared line, so it
  # is left in the member's card for the propagation to take to the
  # group rather than subtracted as the group's own (the plan's "Edits
  # propagate to the group").
  def test_a_relabeled_lent_line_reads_as_an_edit
    relabeled = HOUSEHOLD_ADDRESS.sub("ADR;TYPE=home:", "ADR;type=WORK;type=pref:")

    with_store({"aiden" => AIDEN}) do |store|
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])
      served = store.contact("aiden").vcard.to_s

      store.put("aiden", vcard(served.sub(HOUSEHOLD_ADDRESS, relabeled)))

      assert_includes card_row(store, "aiden").fetch(:vcard), relabeled
      assert_includes store.contact("aiden").vcard.to_s, HOUSEHOLD_ADDRESS
      assert_empty sentry_messages
    end
  end

  # An untyped line comes back untyped: the client invents no type to
  # fill the gap (docs/macos-contacts.md, "An address type the client
  # cannot model becomes a custom label").
  def test_an_untyped_lent_line_comes_back_untyped
    with_store({"aiden" => AIDEN}) do |store|
      add_group(store, members: ["aiden"], lines: [UNTYPED_ADDRESS])
      served = store.contact("aiden").vcard.to_s

      store.put("aiden", vcard(served))

      assert_equal AIDEN, card_row(store, "aiden").fetch(:vcard)
      assert_equal served, store.contact("aiden").vcard.to_s
      assert_empty sentry_messages
    end
  end

  # Which is what makes labelling one an edit like any other relabel:
  # the type it arrives with is the member's, nobody else having put
  # one there.
  def test_a_label_on_an_untyped_lent_line_reads_as_an_edit
    labeled = UNTYPED_ADDRESS.sub("ADR:", "ADR;type=HOME;type=pref:")

    with_store({"aiden" => AIDEN}) do |store|
      add_group(store, members: ["aiden"], lines: [UNTYPED_ADDRESS])
      served = store.contact("aiden").vcard.to_s

      store.put("aiden", vcard(served.sub(UNTYPED_ADDRESS, labeled)))

      assert_includes card_row(store, "aiden").fetch(:vcard), labeled
      assert_includes store.contact("aiden").vcard.to_s, UNTYPED_ADDRESS
      assert_empty sentry_messages
    end
  end

  # An edit still reads as one through the re-serialization it arrives
  # wrapped in: the value moved, and the spelling around it is what the
  # comparison sees past.
  def test_an_edit_survives_the_reserialization_it_arrives_in
    edited = RESERIALIZED_ADDRESS.sub("7 Calculus", "8 Calculus")

    with_store({"aiden" => AIDEN}) do |store|
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])
      served = store.contact("aiden").vcard.to_s

      store.put("aiden", vcard(served.sub(HOUSEHOLD_ADDRESS, edited)))

      assert_includes card_row(store, "aiden").fetch(:vcard), edited
      assert_includes store.contact("aiden").vcard.to_s, HOUSEHOLD_ADDRESS
      assert_empty sentry_messages
    end
  end

  # A deletion is detected and takes nothing with it: the group still
  # lends the line, so the next read composes it back in. Whether a
  # delete should reach the group at all is the plan's open question,
  # and nothing here decides it.
  def test_a_deleted_lent_line_comes_straight_back
    with_store({"aiden" => AIDEN}) do |store|
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])
      served = store.contact("aiden").vcard.to_s

      store.put("aiden", vcard(served.sub("#{HOUSEHOLD_ADDRESS}\r\n", "")))

      assert_equal AIDEN, card_row(store, "aiden").fetch(:vcard)
      assert_equal served, store.contact("aiden").vcard.to_s
      assert_empty sentry_messages
    end
  end

  # Two lines of the lent name, neither of them its bytes: the edit
  # cannot be told from the addition, so the card is stored as it
  # arrived and the ambiguity is reported rather than guessed at.
  def test_two_candidates_for_one_lent_line_are_stored_and_reported
    with_store({"aiden" => AIDEN}) do |store|
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])
      served = store.contact("aiden").vcard.to_s
      submitted = served.sub(HOUSEHOLD_ADDRESS, "#{EDITED_ADDRESS}\r\n#{OWN_ADDRESS}")

      store.put("aiden", vcard(submitted))

      assert_equal submitted, card_row(store, "aiden").fetch(:vcard)
      assert_equal 1, sentry_messages.length
    end
  end

  # A member whose own card spells a line exactly as its group does
  # keeps one copy of it: the stored lines are struck against the
  # submission before anything is attributed to a group, so what is
  # left over is the lent copy and only that one goes.
  def test_a_line_the_member_and_its_group_both_spell_keeps_one_copy
    own = AIDEN.sub("END:VCARD\r\n", "#{HOUSEHOLD_ADDRESS}\r\nEND:VCARD\r\n")

    with_store({"aiden" => own}) do |store|
      add_group(store, members: ["aiden"], lines: [HOUSEHOLD_ADDRESS])
      served = store.contact("aiden").vcard.to_s
      assert_equal 2, served.scan(HOUSEHOLD_ADDRESS).length

      store.put("aiden", vcard(served))

      assert_equal own, card_row(store, "aiden").fetch(:vcard)
      assert_equal served, store.contact("aiden").vcard.to_s
    end
  end

  ## The migration

  # A database at the old action vocabulary — put and delete only — is
  # carried over with its sequences intact: they are every client's
  # sync token state, and a rebuilt table that skipped or reused one
  # would silently drop a change from some client's window.
  def test_the_migration_carries_the_change_log_and_its_sequences
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir) / "contacts.db"
      Sequel.connect("sqlite://#{path}") do |db|
        Sequel::Migrator.run(db, ProTacts::Store::MIGRATIONS.to_s, target: 2)
        db[:changes].insert(card_id: "aiden", action: "put", etag: '"a1"')
        db[:changes].insert(card_id: "aiden", action: "delete", etag: nil)
      end

      ProTacts::Store.connect(path) do |store|
        assert_equal [%w[aiden put], %w[aiden delete]], store.changes.map { [it.card_id, it.action] }
        assert_equal [1, 2], store.changes.map(&:sequence)

        # The widened vocabulary admits the editor's action, and the
        # sequence continues past the copied high-water mark.
        store.put("aiden", vcard(AIDEN))
        store.rewrite("aiden", vcard(AIDEN.sub("FN:Aiden", "FN:Aiden Smith")), birthday: nil)
        change = store.changes.last
        assert_equal %w[aiden edit], [change.card_id, change.action]
        assert_equal 4, change.sequence
      end
    end
  end

  # The group rebuild carries all three tables, and the hazard it is
  # written around is this one: dropping the old groups table with
  # foreign keys on runs an implicit DELETE FROM, and the members and
  # the properties would cascade away behind it. So the members and
  # the properties are asserted across the upgrade, and both cascades
  # asserted still to fire on the far side — a rebuild that forgot to
  # redeclare them would pass the first half of this alone.
  def test_the_migration_carries_a_group_with_its_members_and_properties
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir) / "contacts.db"
      Sequel.connect("sqlite://#{path}") do |db|
        Sequel::Migrator.run(db, ProTacts::Store::MIGRATIONS.to_s, target: 4)
        db[:cards].insert(id: "aiden", vcard: AIDEN)
        db[:groups].insert(id: "nous", name: "Booles")
        db[:group_properties].insert(group_id: "nous", position: 0, line: HOUSEHOLD_ADDRESS)
        db[:group_members].insert(group_id: "nous", card_id: "aiden")
      end

      ProTacts::Store.connect(path) do |store|
        contact = store.contact("aiden")
        assert_includes contact.vcard.to_s, HOUSEHOLD_ADDRESS
        assert_equal "Booles", contact.group_of(contact.addresses.fetch(0).line)

        database(store)[:cards].where(id: "aiden").delete
        assert_empty database(store)[:group_members].all

        database(store)[:groups].where(id: "nous").delete
        assert_empty database(store)[:group_properties].all
      end
    end
  end

  # A database at the old shape — BDAY in the card, no birthdays table
  # — is carried over by the same subtraction a write makes: modeled
  # forms move, unmodeled forms stay put.
  def test_the_migration_moves_a_modeled_bday_out_of_the_cards
    shared = ZED.sub("UID:znorth", "UID:xavi").sub("END:VCARD\r\n", "BDAY:1985-04-12\rNOTE:b\r\nEND:VCARD\r\n")
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir) / "contacts.db"
      Sequel.connect("sqlite://#{path}") do |db|
        Sequel::Migrator.run(db, ProTacts::Store::MIGRATIONS.to_s, target: 1)
        db[:cards].insert(id: "aiden", vcard: AIDEN_BORN)
        db[:cards].insert(id: "znorth", vcard: ZED.sub("END:VCARD\r\n", "BDAY:--0412\r\nEND:VCARD\r\n"))
        db[:cards].insert(id: "xavi", vcard: shared)
      end

      ProTacts::Store.connect(path) do |store|
        assert_equal AIDEN, card_row(store, "aiden").fetch(:vcard)
        assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12), birthday_row(store, "aiden")
        assert_equal AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04-12\r\nEND:VCARD\r\n"), store.contact("aiden").vcard.to_s

        # Unmodeled: byte-identical, no birthday row beside it.
        assert_equal ZED.sub("END:VCARD\r\n", "BDAY:--0412\r\nEND:VCARD\r\n"), store.contact("znorth").vcard.to_s
        assert_nil birthday_row(store, "znorth")

        # A BDAY sharing its line's bytes stays put: the line moves as
        # one or not at all, where the first property alone would have
        # moved the birthday and dropped the NOTE unwitnessed.
        assert_equal shared, store.contact("xavi").vcard.to_s
        assert_nil birthday_row(store, "xavi")
      end
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

  # The birthday row read through the store's own model, so a test sees
  # the shape it holds and not the columns it came from.
  def birthday_row(store, id)
    birthday = database(store)[:birthdays].where(card_id: id).first
    birthday && ProTacts::Birthday.new(year: birthday[:year], month: birthday[:month], day: birthday[:day])
  end

  def wreck_the_index(store)
    database(store)[:card_parameters].delete
    database(store)[:card_properties].update(value: "wrong")
  end
end
