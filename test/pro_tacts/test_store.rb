require_relative "../test_helper"

require "pathname"
require "tmpdir"

require "sequel"

require "pro_tacts/store"

class StoreTest < Minitest::Test
  include CapturingSentry

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

  ## UIDs

  # The read behind the no-uid-conflict precondition (RFC 6352 section
  # 6.3.2.1): which card, if any, owns this UID.
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

  # The lookup runs through the index, whose name column ignores case,
  # so a card that spelled the property lowercase is still found.
  def test_a_lowercase_uid_property_is_found
    lowercase = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Aiden\r\nuid:aiden\r\nEND:VCARD\r\n"

    with_store({"aiden" => lowercase}) do |store|
      assert_equal "aiden", store.card_id_with_uid("aiden")
    end
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

  # The store's contract is UTF-8, and the adapter enforces it: the
  # sqlite3 gem encodes every bound value to UTF-8, so a binary-flagged
  # string with a byte above 7 bits raises at the bind — loudly, at the
  # contract violation, rather than being quietly relabelled here. The
  # route is where Rack's binary becomes text (Web#utf8).
  def test_binary_bytes_above_ascii_raise_at_the_bind
    accented = AIDEN.sub("Aiden", "Aiden Åberg")

    with_store({"aiden" => AIDEN}) do |store|
      assert_raises(Encoding::UndefinedConversionError) do
        store.put("aiden".b, accented.b)
      end

      # Pure ASCII carries no such byte, so a binary-flagged id still
      # finds its row.
      assert_equal AIDEN, store.contact("aiden".b).vcard
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

  def test_contacts_by_recency_orders_newest_first
    with_store({"aiden" => AIDEN}) do |store|
      sleep 0.002
      store.put("znorth", ZED)

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

  # Relabelling bytes is not converting them, so a card whose bytes are
  # not UTF-8 at all is refused rather than stored: better than serving
  # it back as `text/vcard; charset=utf-8` while it is no such thing.
  # Relabelled first, as the route would — a request this bad never
  # reaches the store, and this pins the last line that catches it: the
  # card itself, before any walk or bind could meet the bytes.
  def test_a_card_that_is_not_utf_8_is_refused
    with_store do |store|
      invalid = "BEGIN:VCARD\r\nFN:\xFF\xFE\r\nEND:VCARD\r\n".dup.force_encoding(Encoding::UTF_8)

      error = assert_raises(ArgumentError) do
        store.put("bad", invalid)
      end

      assert_match "not valid UTF-8", error.message
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
      assert_equal "this is not a vCard\r\n", store.contact("broken").vcard
      assert_empty indexed_names(store, "broken")
    end
  end

  # One line the parser cannot read does not cost the card the lines
  # that read: the index is what this server understood, not an
  # all-or-nothing verdict on the card.
  def test_a_card_is_indexed_by_the_lines_that_read
    unreadable = AIDEN.sub("FN:Aiden\r\n", "FN:Aiden\r\nTEL;HOME:+1-555-1234\r\n")
    with_store({"aiden" => unreadable}) do |store|
      assert_equal %w[BEGIN VERSION FN UID END], indexed_names(store, "aiden")
      assert_equal unreadable, store.contact("aiden").vcard
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
      assert_equal AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04-12\r\nEND:VCARD\r\n"), store.contact("aiden").vcard
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
      store.put("aiden", AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04-12\r\nEND:VCARD\r\n"))

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
      store.put("aiden", AIDEN)

      assert_nil birthday_row(store, "aiden")
      assert_equal AIDEN, store.contact("aiden").vcard
    end
  end

  # A birthday no client can see — year alone, month alone, day alone,
  # year and month — survives a round trip the client never saw a
  # birthday in. Planted directly, because no writer produces one yet.
  def test_a_birthday_no_client_can_see_survives_a_card_without_one
    with_store({"aiden" => AIDEN}) do |store|
      database(store)[:birthdays].insert(card_id: "aiden", year: 1985)

      store.put("aiden", AIDEN.sub("FN:Aiden", "FN:Aiden Smith"))

      assert_equal ProTacts::Birthday.new(year: 1985), birthday_row(store, "aiden")
      assert_equal AIDEN.sub("FN:Aiden", "FN:Aiden Smith"), store.contact("aiden").vcard
    end
  end

  # A BDAY the model cannot recompose stays in the card verbatim and
  # empties the model: the card's own line speaks for itself, and
  # compose must never add a second one beside it.
  # A BDAY the model cannot recompose stays in the card verbatim and
  # empties the model: the card's own line speaks for itself, and
  # nothing composes a second one beside it. A fold travels with its
  # line, byte for byte.
  def test_an_unmodeled_bday_stays_in_the_card_and_empties_the_model
    ["BDAY:--0412", "BDAY:1985-\r\n 04\r\n", "BDAY:1985-04-12\r\nBDAY:1986-04-12\r\n"].each do |bday|
      unmodeled = AIDEN.sub("END:VCARD\r\n", "#{bday}END:VCARD\r\n")

      with_store({"aiden" => AIDEN_BORN}) do |store|
        store.put("aiden", unmodeled)

        assert_equal unmodeled, store.contact("aiden").vcard, bday
        assert_nil birthday_row(store, "aiden"), bday
      end
    end
  end

  # The card's half of the same rule. A BDAY in a shape no client
  # renders lives in the card — the model has no spelling for it — and
  # macOS Contacts drops those lines from every card it writes, so a
  # rewrite that omits the BDAY carries them across or loses them
  # (docs/macos-contacts.md, "A birthday the client cannot render is
  # dropped from the card").
  # A BDAY sharing its line's bytes with another content line — a bare
  # CR packs two into one physical line — is a shape the parser is
  # built to assume macOS never sends, so it is never read: the line
  # stays verbatim and the model empties. The store says nothing about
  # it. A value it never read is not a value it failed to recognize,
  # and reporting it as an odd BDAY would send anyone reading the
  # message looking in the wrong place. WebTest holds the report that
  # is worth making, at the arrival.
  def test_a_bday_sharing_its_line_arrives_whole_and_unreported
    shared = AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04-12\rNOTE:b\r\nEND:VCARD\r\n")

    with_store({"aiden" => AIDEN_BORN}) do |store|
      messages = capturing_sentry { store.put("aiden", shared) }

      assert_equal shared, store.contact("aiden").vcard
      assert_nil birthday_row(store, "aiden")
      assert_empty messages
    end
  end

  def test_a_birthday_no_client_renders_survives_a_rewrite_that_drops_it
    ["BDAY:1985-04", "BDAY:1985", "BDAY:--04", "BDAY:---12"].each do |line|
      with_store({"aiden" => AIDEN.sub("END:VCARD\r\n", "#{line}\r\nEND:VCARD\r\n")}) do |store|
        edited = AIDEN.sub("FN:Aiden", "FN:Aiden Smith")

        store.put("aiden", edited)

        assert_equal edited.sub("END:VCARD\r\n", "#{line}\r\nEND:VCARD\r\n"), store.contact("aiden").vcard, line
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
      store.put("aiden", AIDEN)

      assert_equal AIDEN, store.contact("aiden").vcard
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
      messages = capturing_sentry { store.put("aiden", edited) }

      assert_equal edited, store.contact("aiden").vcard
      assert_equal 1, messages.length
    end
  end

  # A submission carrying any BDAY replaces what was there, carried
  # line included: PUT is a whole-card replace, not a merge.
  def test_a_submitted_birthday_replaces_the_carried_line
    with_store({"aiden" => AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04\r\nEND:VCARD\r\n")}) do |store|
      born = AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04-12\r\nEND:VCARD\r\n")

      store.put("aiden", born)

      assert_equal ProTacts::Birthday.new(year: 1985, month: 4, day: 12), birthday_row(store, "aiden")
      assert_equal born, store.contact("aiden").vcard
    end
  end

  # The loss report, the rewrite's half of the arrival one: a stored
  # BDAY no client renders and no whitelist recognizes is about to be
  # dropped, and nobody would know.
  def test_a_rewrite_dropping_an_unrecognized_bday_is_reported
    with_store({"aiden" => AIDEN.sub("END:VCARD\r\n", "BDAY:1985-13\r\nEND:VCARD\r\n")}) do |store|
      messages = capturing_sentry {
        store.put("aiden", AIDEN.sub("FN:Aiden", "FN:Aiden Smith"))
      }

      assert_equal 1, messages.length
      assert_match /BDAY/, messages.fetch(0)
    end
  end

  # A rewrite's quiet cases: a carried line survives (asserted above),
  # a rendered one was deleted by a user who could see it, and a card
  # with no BDAY at all has nothing to say.
  def test_a_rewrite_over_known_bdays_stays_quiet
    ["BDAY:--0412", "BDAY:1985-04"].each do |line|
      with_store({"aiden" => AIDEN.sub("END:VCARD\r\n", "#{line}\r\nEND:VCARD\r\n")}) do |store|
        messages = capturing_sentry {
          store.put("aiden", AIDEN.sub("FN:Aiden", "FN:Aiden Smith"))
        }

        assert_empty messages, line
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
        messages = capturing_sentry {
          store.put("aiden", AIDEN.sub("END:VCARD\r\n", "#{line}\r\nEND:VCARD\r\n"))
        }

        assert_equal 1, messages.length, line
      end
    end
  end

  def test_a_bday_the_server_knows_arrives_quietly
    ["BDAY:1985-04-12", "BDAY:1985-04-12T23:10:00Z", "BDAY;X-APPLE-OMIT-YEAR=1604:1604-04-12",
      "BDAY:--0412", "BDAY:--04-12", "BDAY:1985-04", "BDAY:1985"].each do |line|
      with_store({}) do |store|
        messages = capturing_sentry {
          store.put("aiden", AIDEN.sub("END:VCARD\r\n", "#{line}\r\nEND:VCARD\r\n"))
        }

        assert_empty messages, line
      end
    end
  end

  # The card is made of text and says so itself: bytes that are not
  # UTF-8 raise at the card, before any walk — the web's PUT has
  # already answered them with a 412 by the time one reaches a caller
  # this direct.
  def test_put_of_bytes_that_are_not_text_raises_at_the_card
    invalid = "BEGIN:VCARD\r\nFN:\xFF\r\nEND:VCARD\r\n".dup.force_encoding(Encoding::UTF_8)

    with_store({}) do |store|
      error = assert_raises(ArgumentError) { store.put("aiden", invalid) }

      assert_match "not valid UTF-8", error.message
    end
  end

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

  # The transaction the whole design turns on, now with a third piece:
  # a birthday must not survive a write whose log entry failed.
  def test_a_failed_birthday_write_leaves_no_birthday
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir) / "contacts.db"

      FailingLog.connect(path) do |store|
        assert_raises(RuntimeError) { store.put("aiden", AIDEN_BORN) }
      end

      ProTacts::Store.connect(path) do |store|
        assert_empty store.contacts
        assert_empty database(store)[:birthdays].all
      end
    end
  end

  ## The migration

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
        assert_equal AIDEN.sub("END:VCARD\r\n", "BDAY:1985-04-12\r\nEND:VCARD\r\n"), store.contact("aiden").vcard

        # Unmodeled: byte-identical, no birthday row beside it.
        assert_equal ZED.sub("END:VCARD\r\n", "BDAY:--0412\r\nEND:VCARD\r\n"), store.contact("znorth").vcard
        assert_nil birthday_row(store, "znorth")

        # A BDAY sharing its line's bytes stays put: the line moves as
        # one or not at all, where the first property alone would have
        # moved the birthday and dropped the NOTE unwitnessed.
        assert_equal shared, store.contact("xavi").vcard
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
