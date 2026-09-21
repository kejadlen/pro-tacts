# For the operations no screen has: deleting a contact outright,
# dissolving a group. The session loads console.rb at the root, which
# opens the store; exec rather than sh, so the console is the process
# the terminal talks to and Ctrl-D ends it rather than a rake around
# it.
#
# Before the prompt, the dump is taken, and taking it is committing it
# (tasks/db.rake), so a session starts from a recorded snapshot of the
# three things the store cannot rebuild and a mistake at the prompt is
# a revert in the dump's repository rather than a restore from backup.
# db:dump raising is what keeps the console from opening on a session
# its safety net never armed.
desc "Open an irb console on the configured database, the dump committed first"
task :console do
  Rake::Task["db:dump"].invoke

  exec "bundle", "exec", "irb", "-I", "lib", "-r", "./console"
end
