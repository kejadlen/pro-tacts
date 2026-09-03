require "pro_tacts/warnings"

# The admin's phlex require. Phlex lazy-loads: `require "phlex"`
# registers autoloads and the files that warn -- a page of
# mismatched-indentation and method-redefined warnings under `ruby
# -w`, which the test task runs -- compile only when Phlex::HTML is
# first referenced, by then outside any block. So this loads phlex's
# own files eagerly inside the silence; the views require this file
# instead of phlex, and every later require or autoload hit is a
# no-op. sgml/state is in the set because it loads later still, at
# the first render, and carries its own warning.
#
# Two warnings survive on purpose: sgml.rb passes &block to
# before_template and after_template, which ignore it, and Ruby warns
# once per process at the first render carrying a content block. The
# only way to spend that render inside the silence is a throwaway
# component redefining view_template at require time, which costs more
# than the two lines of noise it saves.
ProTacts.silence_warnings do
  require "phlex"
  require "phlex/html"
  require "phlex/sgml/state"
end
