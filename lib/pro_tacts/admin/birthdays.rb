require "phlex"

require "pro_tacts/admin/format"
require "pro_tacts/admin/layout"

module ProTacts
  module Admin
    # GET /birthdays — who has a birthday soon, in the order they
    # arrive, each row opening the contact's card. The store's query
    # has already decided the hard parts (arrival order, the year
    # wrap, which partial shapes land on a day at all); this screen
    # only renders what it hands back, and a birthday with no year
    # shows its day without an age.
    class Birthdays < Phlex::HTML
      LIMIT = 10

      #: (upcoming: Array[Store::UpcomingBirthday]) -> void
      def initialize(upcoming:)
        @upcoming = upcoming
      end

      def view_template
        render Layout.new(title: "Birthdays") do
          h1(class: "type-h1") { "Birthdays" }
          if @upcoming.empty?
            p(class: "type-body-sm") { "No birthdays to show." }
          else
            ul(class: "card") { @upcoming.each { render_row(it) } }
          end
        end
      end

      private

      #: (Store::UpcomingBirthday upcoming) -> void
      def render_row(upcoming)
        contact = upcoming.contact
        a(href: "/contacts/#{contact.id}") do
          span(class: "avatar") { Format.initials(contact) }
          div(style: "flex: 1; min-width: 0;") do
            div(style: "font-weight: 550;") { contact.name || contact.id }
            div(class: "type-body-sm") { date_line(upcoming) }
          end
          span(class: "type-label") { Format.time_until(upcoming.occurs_on) }
        end
      end

      # The birthday as the contact's own card shows it, with the age
      # it turns on the day when the year is there to know it from.
      #: (Store::UpcomingBirthday upcoming) -> String
      def date_line(upcoming)
        birthday = upcoming.contact.birthday
        text = Format.birthday(upcoming.contact).to_s
        return text if birthday.nil? || birthday.year.nil?

        "#{text} (turns #{upcoming.occurs_on.year - birthday.year})"
      end
    end
  end
end
