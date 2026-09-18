require_relative "../test_helper"

require "pathname"
require "rake"
require "tmpdir"

require "pro_tacts/import/plan"

class ImportStatusTaskTest < Minitest::Test
  Plan = ProTacts::Import::Plan

  SOURCE = {"identifier" => "A:ABPerson", "vcard" => "BEGIN:VCARD\r\nEND:VCARD\r\n", "note" => nil, "contact" => {}}
  ADA = ProTacts::Import::Card.new(first: "Ada", last: "Lovelace", nickname: nil, birthday: nil, phones: [], emails: [], addresses: [], note: nil, photo: false, groups: [], source: SOURCE)

  def entry(id) = Plan::Entry.new(id:, source_id: "#{id}:ABPerson", card: ADA)

  def test_status_counts_each_plans_contacts_and_names_what_comes_next
    Dir.mktmpdir do |root|
      root = Pathname.new(root)
      imports = root / "data" / "imports"
      # A plan mid-flight — one contact through to the Mac-cleanup step,
      # one past it — and one freshly built with everything still to do.
      underway = Plan.write(imports / "macos-20260901T000000Z", source: "macos", created_at: Time.utc(2026, 9, 1), entries: [entry("kmnuqmzxylru"), entry("vmnlryyvktux")])
      underway.host = "https://contacts.example"
      underway.record("kmnuqmzxylru", "imported")
      underway.record("vmnlryyvktux", "removed")
      Plan.write(imports / "macos-20260916T180412Z", source: "macos", created_at: Time.utc(2026, 9, 16, 18, 4, 12), entries: [entry("aaaaaaaaaaaa")])

      out, = run_task(root)

      assert_includes out, "macos-20260901T000000Z  macos  on https://contacts.example"
      assert_includes out, "  2 contacts: 1 imported, 1 removed"
      assert_includes out, "macos-20260916T180412Z  macos  not yet on a host"
      assert_includes out, "  1 contact: 1 to land"
      assert_includes out, "next: import:execute would land macos-20260916T180412Z"
      assert_includes out, "next: import:macos:remove would clear macos-20260901T000000Z"
    end
  end

  def test_status_with_no_plans_says_how_to_build_one
    Dir.mktmpdir do |root|
      out, = run_task(Pathname.new(root))

      assert_includes out, "no plans in data/imports yet"
    end
  end

  private

  # Runs import:status in a Rake application of its own, from root as
  # the working directory: the task reads data/imports relative to
  # where rake runs, not through ProTacts.config.
  def run_task(root)
    application = Rake.application
    Rake.application = Rake::Application.new
    load (Pathname.new(__dir__).parent.parent / "tasks" / "import.rake").to_s
    Dir.chdir(root) { capture_io { Rake.application["import:status"].invoke } }
  ensure
    Rake.application = application
  end
end
