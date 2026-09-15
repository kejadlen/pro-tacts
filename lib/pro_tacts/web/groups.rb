require "pro_tacts/admin/card_form"
require "pro_tacts/admin/groups_edit"
require "pro_tacts/admin/groups_index"
require "pro_tacts/admin/groups_show"

module ProTacts
  class Web < Roda
    # The group screens, the contacts' own shape: the collection's
    # GET and create, then a record's GET, its editor, and the POST
    # that applies it. What the writes rest on is
    # docs/plans/2026-09-09-group-edits-propagate.md. A create lands
    # on the editor, a new group being nothing until something is
    # added to it.
    hash_branch("groups") do |r|
      r.is do
        r.get do
          response["Content-Type"] = "text/html; charset=utf-8"
          Admin::GroupsIndex.call(groups: store.all_groups)
        end

        r.post do
          name = r.params["name"].to_s.strip
          id = store.create_group(name: name.empty? ? nil : name)
          r.redirect "/groups/#{id}/edit", 303
        rescue Sequel::UniqueConstraintViolation
          # A taken name (db/migrations/008_group_names.rb).
          response["Content-Type"] = "text/html; charset=utf-8"
          Admin::GroupsIndex.call(groups: store.all_groups, notice: "Another group is already named #{name}.")
        end
      end

      r.on String do |id|
        r.get "edit" do
          group = store.group(id)
          group_edit_screen(group) if group
        end

        r.post do
          apply_group_edit(r, id)
        end

        r.get do
          group = store.group(id)

          if group
            response["Content-Type"] = "text/html; charset=utf-8"
            Admin::GroupsShow.call(group:, members: members_of(group))
          end
        end
      end
    end

    private

    # The group editor's POST, #apply_edit's shape over a group: the
    # snapshot guard, then the lines the form splices
    # (Admin::CardForm.group_lines), and one store write for the lot.
    #: (untyped r, String id) -> String?
    def apply_group_edit(r, id)
      group = store.group(id)
      return if group.nil?

      if r.params["version"].to_s != group.version
        return group_edit_screen(group, notice: "This group changed since the page loaded; nothing was saved.")
      end

      # Only ids that name a card: a membership row is a foreign key,
      # and a doctored id is ordinary bad input rather than a 500. A
      # POST carrying no list keeps the membership it found, the
      # phones' is-a-Hash posture (Admin::GroupsEdit).
      submitted = r.params["members"]
      members =
        if submitted.is_a?(Array)
          submitted.map(&:to_s) & store.contacts.map(&:id)
        else
          group.members
        end #: Array[String]

      begin
        store.edit_group(id, name: r.params["name"].to_s, lines: Admin::CardForm.group_lines(group, r.params), members:)
      rescue Sequel::UniqueConstraintViolation
        # A taken name (db/migrations/008_group_names.rb). The save is
        # one transaction, so nothing of it landed.
        return group_edit_screen(group, notice: "Another group is already named #{r.params['name']}; nothing was saved.")
      end
      r.redirect "/groups/#{id}", 303
    end

    #: (Store::Group group, ?notice: String) -> String
    def group_edit_screen(group, notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::GroupsEdit.call(group:, notice:)
    end

    # A group's members as contacts, in the listing's own order.
    #: (Store::Group group) -> Array[Contact]
    def members_of(group)
      store.contacts.select { group.members.include?(it.id) }
    end
  end
end
