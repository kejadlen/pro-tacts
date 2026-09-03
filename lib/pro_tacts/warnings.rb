module ProTacts
  # Turns the interpreter's warnings off for the block and restores
  # them after -- including on raise -- so code that is noisy under
  # -w can run quietly without silencing anything else. $VERBOSE is
  # the global switch the interpreter reads, not a thread-local one,
  # so this belongs at boot-time requires and not on request paths.
  # Used to require phlex, whose files warn by the page (see
  # admin/phlex.rb).
  #: [T] () { () -> T } -> T
  def self.silence_warnings
    verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = verbose
  end
end
