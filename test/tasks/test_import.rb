require_relative "../test_helper"

require "pathname"
require "rake"
require "tmpdir"

require "pro_tacts/import/plan"

class ImportTasksTest < Minitest::Test
  Plan = ProTacts::Import::Plan

  SOURCE = {"identifier" => "A:ABPerson", "vcard" => "BEGIN:VCARD\r\nEND:VCARD\r\n", "note" => nil, "contact" => {}}
  ADA = ProTacts::Import::Card.new(first: "Ada", last: "Lovelace", nickname: nil, birthday: nil, phones: [], emails: [], addresses: [], note: nil, photo: false, groups: [], source: SOURCE)

  def entry(id) = Plan::Entry.new(id:, source_id: "#{id}:ABPerson", card: ADA)

  def test_status_counts_each_plans_contacts_and_files_finished_plans_away
    Dir.mktmpdir do |root|
      root = Pathname.new(root)
      plans = root / "data" / "import" / "active"
      # A plan carried all the way off the Mac — done, so swept into
      # done/ rather than listed — one mid-flight with a contact through
      # to the finalizing step and one past it, and one freshly built
      # with everything to do.
      through = Plan.write(plans / "macos-20260831T000000Z", source: "macos", created_at: Time.utc(2026, 8, 31), entries: [entry("qxqmqmqmqmqm"), entry("zzzzzzzzzzzz")])
      through.contacts.each { it.status or through.record(it.id, Plan::DONE) }
      underway = Plan.write(plans / "macos-20260901T000000Z", source: "macos", created_at: Time.utc(2026, 9, 1), entries: [entry("kmnuqmzxylru"), entry("vmnlryyvktux")])
      underway.record("kmnuqmzxylru", "imported")
      underway.record("vmnlryyvktux", Plan::DONE)
      Plan.write(plans / "macos-20260916T180412Z", source: "macos", created_at: Time.utc(2026, 9, 16, 18, 4, 12), entries: [entry("aaaaaaaaaaaa")])

      out, = run_status(root)

      assert_includes out, "macos-20260901T000000Z  2/2 contacts\n"
      assert_includes out, "macos-20260916T180412Z  0/1 contacts\n"
      assert_includes out, "next: import:execute would land macos-20260916T180412Z\n"
      assert_includes out, "next: import:macos:finalize would finish macos-20260901T000000Z\n"
      assert (root / "data/import/done/macos-20260831T000000Z/plan.yml").file?
      refute (plans / "macos-20260831T000000Z").directory?
      refute_includes out, "macos-20260831T000000Z  "
    end
  end

  def test_status_with_no_plans_says_how_to_build_one
    Dir.mktmpdir do |root|
      out, = run_status(Pathname.new(root))

      assert_includes out, "no plans in data/import/active; run rake import:macos:plan"
    end
  end

  private

  def run_status(root)
    with_import_tasks(root) { capture_io { Rake.application["import:status"].invoke } }
  end

  # Loads tasks/import.rake in a Rake application of its own, from root
  # as the working directory: the tasks read data/import relative to
  # where rake runs, not through ProTacts.config.
  def with_import_tasks(root)
    application = Rake.application
    Rake.application = Rake::Application.new
    load (Pathname.new(__dir__).parent.parent / "tasks" / "import.rake").to_s
    Dir.chdir(root) { yield }
  ensure
    Rake.application = application
  end
end
