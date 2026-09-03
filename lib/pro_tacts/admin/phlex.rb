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
ProTacts.silence_warnings do
  require "phlex"
  require "phlex/html"
  require "phlex/sgml/state"

  # Two warnings survive the requires: sgml.rb passes &block to
  # before_template and after_template, methods that ignore it, and
  # Ruby warns once per process at the first render carrying a
  # content block -- the render(Layout.new) { ... } shape every
  # screen here uses. Spending that first render now, on a throwaway
  # component whose output is discarded, means no later one warns.
  inner = Class.new(Phlex::HTML) { def view_template; h1 { "warm" }; end }
  Class.new(Phlex::HTML) do
    define_method(:view_template) { render inner.new { nil } }
  end.new.call
end
