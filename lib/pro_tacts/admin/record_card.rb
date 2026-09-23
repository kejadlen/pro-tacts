require "pro_tacts/admin/phlex"

module ProTacts
  module Admin
    # The trunk every form card shares: the record's caption row and
    # card (admin.css), the form as the card's body, and the action
    # bar under both — a shape ContactsEdit, GroupsEdit, and
    # ImportUpload each carried by hand before this.
    #
    # The form is the caller's block rather than the component's,
    # because its rhythm is the caller's question: an editor's rows
    # are a field-stack on the record's grid, and an upload's lone
    # field is a Gloss settings field with no grid to align to.
    # Everything around the form is the same for all three, which is
    # why it lives here.
    #
    # `back` names the caption row's link, `[href, label]`, the label
    # a string or whatever `render` takes (GroupsEdit's is a
    # GroupLabel). `nav`, when something is passed, is the row's one
    # action at its right edge. The footer's Cancel goes where the
    # back link goes — the editors' own rule — and the submit reaches
    # the form by id rather than sitting in it, so the action bar is
    # the card's and not the form's.
    class RecordCard < Phlex::HTML
      # @rbs @back: [String, (String | Phlex::HTML | Proc)]
      # @rbs @nav: (Proc | Phlex::HTML)?
      # @rbs @heading: String?
      # @rbs @aside: Phlex::HTML?
      # @rbs @sidebar: Phlex::HTML?
      # @rbs @submit: String
      # @rbs @form: String

      #: (back: [String, (String | Phlex::HTML | Proc)], submit: String, form: String, ?nav: (Proc | Phlex::HTML)?, ?heading: String?, ?aside: Phlex::HTML?, ?sidebar: Phlex::HTML?) -> void
      def initialize(back:, submit:, form:, nav: nil, heading: nil, aside: nil, sidebar: nil)
        @back = back
        @nav = nav
        @heading = heading
        @aside = aside
        @sidebar = sidebar
        @submit = submit
        @form = form
      end

      def view_template(&)
        sidebar = @sidebar
        return record(&) if sidebar.nil?

        walk(sidebar, &)
      end

      private

      # The walk's list of contacts, and the record beside it when
      # there is one — the sidebar grid (admin.css). Skipped rather
      # than rendered around one column for the reason #paired is:
      # an ordinary edit has no walk to stand in.
      #: (Phlex::HTML sidebar) { () -> void } -> void
      def walk(sidebar, &)
        div(class: "walk") do
          render sidebar
          record(&)
        end
      end

      # The caption-to-card block the details page uses (.record in
      # admin.css): the back link is this card's caption row, and the
      # row's one action sits at its right edge — the same place, and
      # the same shape, as the details page's edit link. Each mode's
      # row names the other thing you can do to the record from it.
      def record(&)
        div(class: "record") do
          div(class: "record-nav") do
            href, label = @back
            a(href:, class: "type-label") do
              plain "‹ "
              render label
            end
            render @nav if @nav
          end
          paired(&)
        end
      end

      # The editor's card, and what stands beside it when something
      # does — the two-column grid the dashboard uses, for its reason
      # (admin.css). With nothing beside it the wrapper is skipped
      # rather than rendered around one card: a grid of one is a
      # different element for no difference on screen.
      #: () { () -> void } -> void
      def paired(&)
        aside = @aside
        return card(&) if aside.nil?

        div(class: "paired") do
          render aside
          card(&)
        end
      end

      def card(&)
        div(class: "card") do
          div(class: "card-body") do
            h1(class: "type-h2") { @heading } if @heading
            yield
          end
          # A dialog footer's shape (admin.css), outside the form and
          # reaching it by id. The submit is the form's; Cancel is
          # navigation — a link in Gloss's `.btn` contract, which is
          # what an anchor that acts like a button opts into.
          footer do
            a(href: @back.fetch(0), class: "btn") { "Cancel" }
            button(type: "submit", form: @form, data: {variant: "primary"}) { @submit }
          end
        end
      end
    end
  end
end
