module ProTacts
  module Admin
    # The name fields' one rule, for the create dialog and the editor
    # both: a contact needs a name, and either half alone is one — a
    # mononym is a family name alone as often as a given one (macOS
    # writes `N:Prince;;;;`). No attribute says "one of these two", so
    # each box is required exactly while the other is blank: rendered
    # so from the values the form starts with, and kept so by Alpine as
    # they change. The server's refusal of a save blank throughout
    # (Web's contacts routes) is the backstop behind it.
    #
    # The middle box the same forms carry is not one of the halves and
    # is not here: nobody is known by a middle name alone, so it is
    # never required and has no state to share.
    #
    # Not a view, so the Steepfile checks it.
    module NamePair
      # The Alpine state the two boxes share, as properties for the
      # enclosing x-data — booleans, so no name is spliced into script.
      #: (String? first, String? last) -> String
      def self.state(first, last)
        "firstBlank: #{blank?(first)}, lastBlank: #{blank?(last)}"
      end

      # `guard` names an Alpine state the pair stands behind — the
      # create dialog's company toggle, which hides the pair and must
      # stop it demanding a name while hidden: a required box the
      # visitor cannot see blocks the submit the toggle asked for.
      #: (String? first, String? last, ?guard: String?) -> Hash[Symbol, untyped]
      def self.first(first, last, guard: nil)
        box("first", first, required: blank?(last), own: "firstBlank", other: "lastBlank", guard:)
      end

      #: (String? first, String? last, ?guard: String?) -> Hash[Symbol, untyped]
      def self.last(first, last, guard: nil)
        box("last", last, required: blank?(first), own: "lastBlank", other: "firstBlank", guard:)
      end

      #: (String name, String? value, required: bool, own: String, other: String, ?guard: String?) -> Hash[Symbol, untyped]
      def self.box(name, value, required:, own:, other:, guard: nil)
        {type: "text", name:, value:, required:, ":required": [guard, other].compact.join(" && "),
         "@input": "#{own} = !$el.value.trim()"}
      end

      # The server's own test of a blank half (Web's contacts routes).
      #: (String? value) -> bool
      def self.blank?(value)
        value.to_s.strip.empty?
      end
    end
  end
end
