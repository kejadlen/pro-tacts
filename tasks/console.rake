# For the operations no screen has: deleting a contact outright,
# dissolving a group. The session loads console.rb at the root, which
# opens the store; exec rather than sh, so the console is the process
# the terminal talks to and Ctrl-D ends it rather than a rake around
# it.
desc "Open an irb console on the configured database (console.rb loads it)"
task :console do
  exec "bundle", "exec", "irb", "-I", "lib", "-r", "./console"
end
