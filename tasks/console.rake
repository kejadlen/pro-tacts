require "open3"
require "pathname"

# For the operations no screen has: deleting a contact outright,
# dissolving a group. The session loads console.rb at the root, which
# opens the store; exec rather than sh, so the console is the process
# the terminal talks to and Ctrl-D ends it rather than a rake around
# it.
#
# Before the prompt, the dump is taken and committed, so a session
# starts from a recorded snapshot of the three things the store cannot
# rebuild (cards, birthdays, groups — the tables tasks/db.rake dumps)
# and a mistake at the prompt is a revert in the dump's repository
# rather than a restore from backup. This is the one place the tooling
# runs git — the app still runs none
# (docs/plans/2026-09-12-database-dump.md) — and the dump directory is
# its own repository beside the code's, `data/` being ignored here.
desc "Open an irb console on the configured database, the dump committed first"
task :console do
  Rake::Task["db:dump"].invoke

  require "pro_tacts"
  dump = Pathname.new(ENV.fetch("DUMP") { (ProTacts.config.data_dir / "dump").to_s })
  sh "git", "-C", dump.to_s, "init", "-b", "main" unless (dump / ".git").exist?
  sh "git", "-C", dump.to_s, "add", "--all"

  # Porcelain is the whole answer: empty means nothing to commit. A
  # failure here must stop the console from opening rather than start
  # a session its safety net never armed.
  staged, error, = Open3.capture3("git", "-C", dump.to_s, "status", "--porcelain")
  raise error unless error.empty?
  unless staged.empty?
    sh "git", "-C", dump.to_s,
       "-c", "user.name=pro-tacts console", "-c", "user.email=console@localhost",
       "-c", "commit.gpgsign=false",
       "commit", "--message", "console snapshot #{Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")}"
  end

  exec "bundle", "exec", "irb", "-I", "lib", "-r", "./console"
end
