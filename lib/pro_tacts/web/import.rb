require "pro_tacts/admin/card_form"
require "pro_tacts/admin/contacts_edit"
require "pro_tacts/admin/format"
require "pro_tacts/admin/import_groups"
require "pro_tacts/admin/import_original"
require "pro_tacts/admin/import_saved"
require "pro_tacts/admin/import_sidebar"
require "pro_tacts/admin/import_target"
require "pro_tacts/admin/import_upload"
require "pro_tacts/birthday"
require "pro_tacts/import/match"
require "pro_tacts/import/merge"
require "pro_tacts/import/monica"
require "pro_tacts/import/write"
require "pro_tacts/import/staged"
require "pro_tacts/import/vcf"

module ProTacts
  class Web < Roda
    # The import screens: a .vcf, read, looked over contact by
    # contact beside the list of them (Admin::ImportSidebar), and
    # written into the store a Save at a time
    # (docs/plans/2026-09-21-import-a-vcf.md, "The walk" through
    # "Nothing waits for the end").
    #
    # Every screen re-reads the whole staged file, so each step that
    # grows with it is a span (Web#span) counting cards, never their
    # content.
    #
    # Under the same identity gate as every other route (web.rb). A
    # card this creates is ticked into everyone's book rather than the
    # importer's own, so the person importing does not have to be the
    # person syncing.
    hash_branch("import") do |r|
      r.is do
        r.get do
          import_screen
        end

        r.post do
          stage_upload(r)
        end
      end

      r.on String do |upload|
        # The contact's place in the file is its name here, until its
        # own Save mints one. The file's own order is the one thing
        # about a card that cannot change under the walk: the editor's
        # save rewrites a card in place and never adds or removes one.
        r.on Integer do |index|
          r.is do
            # `into` is the contact the row's editor is folding its
            # card into, chosen at the top of that editor
            # (Admin::ImportTarget): an empty `into` is the new contact
            # chosen against the default, and none at all the default
            # itself, the contact the card looks like most.
            r.get do
              card_screen(upload, index, into: r.params.key?("into") ? r.params["into"].to_s : nil)
            end

            r.post do
              save_card(r, upload, index)
            end
          end

          # The stored contact's editor, reached from its row's read
          # screen: the same amend the contact's own page's edit link
          # writes, kept inside the walk (Web#edit_card_screen). A
          # row still to do is already its editor, so its edit is the
          # row screen itself.
          r.get "edit" do
            edit_card_screen(r, upload, index)
          end
        end
      end
    end

    private

    # The upload's own POST: the file — a .vcf, or a Monica export
    # read as one — read and judged whole before anything is staged,
    # so a source that will not read brings in nothing. What it
    # stages is both readings —
    # the file as it arrived, and the cards pared to what this book
    # shows — and then it is the walk's first card.
    #: (untyped r) -> untyped
    def stage_upload(r)
      upload = file_in(r.params["vcf"])
      return import_screen(notice: "Choose a .vcf or Monica export to import.") if upload.nil?

      name = File.basename(upload[:filename].to_s)
      # Relabelled and judged in the same breath, Web#write_card's rule
      # for the one other body this app reads: a multipart part arrives
      # as binary.
      bytes = upload.fetch(:tempfile).read.force_encoding(Encoding::UTF_8)
      return import_screen(notice: "#{name} is not UTF-8 text.") unless bytes.valid_encoding?

      begin
        # A Monica export is read as the cards it composes, and from
        # here on is a .vcf like any other (Import::Monica).
        bytes = span("import.monica") { Import::Monica.vcf(bytes) } if Import::Monica.export?(bytes)
        cards = span("import.split") { |step| Import::Vcf.cards(bytes).tap { step.set_attribute("cards", it.length) } }
      rescue Import::Vcf::Invalid => error
        return import_screen(notice: error.message)
      end

      revised = span("import.pare") { cards.map { Import::Vcf.read(it).card } }
      id = span("import.stage") {
        Import::Staged.open(
          original: bytes,
          revised: joined(revised),
          # Named now and never renamed (the plan's "Nothing waits
          # for the end"); its membership is ticked a contact at a time
          # (#import_picker).
          group: Import::Write.default_group,
        )
      }
      # Straight to the first contact (the plan's "The walk"): the
      # list's first row (#walk_order), not the file's first card. A
      # 303, the other writes' answer, because every screen of the
      # walk is a GET a back button can revisit.
      r.redirect "/import/#{id}/#{walk_order(import_contacts(revised)).fetch(0)}", 303
    end

    # The walk's list of contacts, as every screen of it shows them:
    # the contact each card will be written as, how many of its
    # original's lines are not coming with it, and which rows are in
    # the book already. `current` is the row whose screen is open.
    #: (String upload, Array[VCard] originals, Array[VCard] revised, Hash[String, String] saved, current: Integer) -> Admin::ImportSidebar
    def walk_sidebar(upload, originals, revised, saved, current:)
      rows = span("import.sidebar") {
        contacts = import_contacts(revised)
        walk_order(contacts).map { |index|
          dropped = Import::Vcf.read(originals.fetch(index)).dropped
          [contacts.fetch(index), Import::Vcf.losses(dropped).length, index] #: [Contact, Integer, Integer]
        }
      }
      Admin::ImportSidebar.new(upload:, rows:, saved:, current:)
    end

    # The rows' places in the file, in the order the list shows them:
    # the contacts page's (Format.sort_key), so a file reads the way
    # the book it is joining does. The place in the file breaks a tie
    # where the book's id would, as a number: a row's id is that place
    # spelled as a string, and "10" sorts before "2". A row is still
    # named by its place (the Integer route), which a save cannot
    # move; its position in the list is read off the revised cards
    # afresh on every screen, so a family name changed on the way in
    # moves its row the way it would move the contact's. The contacts
    # rather than the cards, so the sidebar sorts the ones it shows
    # instead of reading every card a second time.
    #: (Array[Contact] contacts) -> Array[Integer]
    def walk_order(contacts)
      span("import.walk_order") {
        contacts.each_index.sort_by { |index| [Admin::Format.sort_key(contacts.fetch(index)), index] }
      }
    end

    # A row opened: the card it arrived as beside the contact editor
    # itself (docs/plans/2026-09-21-import-a-vcf.md, "The walk").
    #
    # A row this walk has saved opens over the stored contact, to read
    # rather than to submit (Admin::ImportSaved; the plan's "Nothing
    # waits for the end"). A stored id naming no contact (deleted
    # from the book since its Save) is the unsaved screen, there
    # being nothing stored to open; its Save is the import POST's own
    # double-write guard to catch.
    #
    # A row not saved yet can be written two ways, and `into` says
    # which: nil for the screen no choice was made about, which folds
    # into the contact the card looks like most (Import::Match), blank
    # for a new contact, or the id of one the book already has, whose
    # editor this becomes with the card folded in (Import::Merge), the
    # lines the fold leaves behind struck beside it. An id naming
    # nobody (a contact deleted since the toggle was drawn) is the new
    # contact, there being nothing to fold into.
    #
    # `joined` and `named` are the groups a refused save had ticked,
    # and none on the way in: nothing is staged between screens (the
    # plan's "Writing them in").
    #: (String upload, Integer index, ?into: String?, ?notice: String?, ?joined: Array[String]?, ?named: Array[String]?) -> String?
    def card_screen(upload, index, into: "", notice: nil, joined: nil, named: nil)
      staged = staged_cards(upload)
      return expired_screen if staged.nil?

      originals, revised = staged
      original = originals[index]
      card = revised[index]
      # An index past the end of the file is the empty-body 404 the
      # not_found handler fills in, the same as a contact id nobody
      # has.
      return nil if original.nil? || card.nil?

      group, saved = Import::Staged.saved(upload)
      stored = saved[index.to_s]
      contact = stored ? store.contact(stored) : nil
      dropped = Import::Vcf.read(original).dropped
      sidebar = walk_sidebar(upload, originals, revised, saved, current: index)

      response["Content-Type"] = "text/html; charset=utf-8"
      return span("import.render") {
        Admin::ImportSaved.call(
          contact:,
          login: @login,
          groups: store.groups_of(contact.id),
          all_groups: store.group_choices,
          aside: Admin::ImportOriginal.new(card: original, dropped:),
          sidebar:,
          edit: "/import/#{upload}/#{index}/edit",
          land: "/import/#{upload}/#{index}",
          notice:,
        )
      } if contact

      arriving = import_contact(card, index)
      book = span("import.contacts") { |step| store.contacts.tap { step.set_attribute("rows", it.length) } }
      matches = span("import.match") { Import::Match.candidates(arriving, book) }
      target = into.nil? || into.empty? ? nil : store.contact(into)
      # The row opened with no choice made is the first choice
      # offered, the best match
      # (docs/plans/2026-09-23-update-is-the-default.md).
      target ||= matches.first if into.nil?
      merge = target && span("import.merge") { Import::Merge.new(target, card) }
      span("import.render") {
        Admin::ContactsEdit.call(
          contact: merge ? merge.contact : arriving,
          login: @login,
          notice:,
          action: "/import/#{upload}/#{index}",
          # The submit says what it does, this being the one editor
          # whose Save can create the record (the plan's "The walk"). An
          # update names the contact it writes, the two modes differing
          # nowhere else the eye lands.
          save: target ? "Update #{target.name || target.id}" : "Import",
          aside: Admin::ImportOriginal.new(card: original, dropped: merge ? dropped + merge.left : dropped),
          fields: import_picker(group, joined, named, member: target,
                                                      tags: Import::Vcf.categories(original) + Import::Monica.groups(original)),
          lead: import_target(upload, index, matches, target),
          sidebar:,
        )
      }
    end

    # The toggle at the top of an unsaved row's editor, or none when
    # nothing in the book looks like the card: the contacts it might
    # be (Import::Match), read off the card as it arrived rather than
    # as the fold would make it. The one being updated is always among
    # them — a toggle has to show the side it is on, and a contact
    # edited since it was offered can have stopped looking like the
    # card.
    #: (String upload, Integer index, Array[Contact] matches, Contact? target) -> Admin::ImportTarget?
    def import_target(upload, index, matches, target)
      matches = [target, *matches] if target && matches.none? { it.id == target.id }
      return nil if matches.empty?

      Admin::ImportTarget.new(row: "/import/#{upload}/#{index}", matches:, into: target)
    end

    # The editor over a stored row's contact, reached from that row's
    # read screen: #apply_edit's form — the contact's own card, its
    # etag, no group boxes — posting to the row itself, where the
    # amend branch of #save_card answers (its `refuse` and `land` are
    # this screen and the row's). `contact` is the fresh one a
    # refusal is re-rendering, and none passed means the stored one;
    # a row with nothing stored is already its editor, so its edit
    # goes back to the row screen.
    #: (untyped r, String upload, Integer index, ?contact: Contact?, ?notice: String?) -> untyped
    def edit_card_screen(r, upload, index, contact: nil, notice: nil)
      staged = staged_cards(upload)
      return expired_screen if staged.nil?

      originals, revised = staged
      original = originals[index]
      return nil if original.nil?

      _group, saved = Import::Staged.saved(upload)
      stored = saved[index.to_s]
      contact ||= stored ? store.contact(stored) : nil
      return r.redirect "/import/#{upload}/#{index}", 303 if contact.nil?

      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ContactsEdit.call(
        contact:,
        login: @login,
        notice:,
        action: "/import/#{upload}/#{index}",
        save: "Save",
        aside: Admin::ImportOriginal.new(card: original, dropped: Import::Vcf.read(original).dropped),
        sidebar: walk_sidebar(upload, originals, revised, saved, current: index),
      )
    end

    # The groups beside one card: this book's own list, ticked with
    # the import's group (a staged name until the first Save makes it,
    # Import::Write#group_id) and everyone's book where it exists yet
    # (docs/plans/2026-09-21-import-a-vcf.md, "Writing them in"). A
    # fold into `member` ticks that contact's groups instead of
    # everyone's book, sent back as `was[]`
    # (docs/plans/2026-09-23-merging-on-import.md, "The Save"). The
    # card's own tags are ticked too, as a group or a name to make,
    # less any spelling a sync group
    # (docs/plans/2026-09-25-importing-from-monica.md, "Tags are
    # groups").
    #: (String group, Array[String]? joined, Array[String]? named, ?member: Contact?, ?tags: Array[String]) -> Admin::ImportGroups
    def import_picker(group, joined, named, member: nil, tags: [])
      choices = store.group_choices
      lot = group.empty? ? nil : choices.find { it.name == group }
      everyone = choices.find { it.name == Group::EVERYONE }
      none = [] #: Array[String]
      was = member ? store.groups_of(member.id).map(&:id) : none
      ticked = member ? was : [everyone&.id].compact
      tags = tags.reject { Group.sync_name?(it) }
      tagged = choices.select { tags.include?(it.name) }
      Admin::ImportGroups.new(
        groups: choices,
        joined: joined || [*ticked, lot&.id, *tagged.map(&:id)].compact.uniq,
        named: named || [(group unless lot || group.empty?), *(tags - tagged.map(&:name))].compact.uniq,
        was:,
      )
    end

    # The editor's save, which is this contact's import: #apply_edit's
    # shape over a card that is not a contact yet, down to the
    # refusals, because it is the same form — and then the write, the
    # card and its groups going in together.
    #: (untyped r, String upload, Integer index) -> untyped
    def save_card(r, upload, index)
      staged = staged_cards(upload)
      return expired_screen if staged.nil?

      _originals, revised = staged
      card = revised[index]
      return nil if card.nil?

      _group, saved = Import::Staged.saved(upload)
      # A Save pressed twice, or a back button onto the editor of a
      # contact that is already in the book: a second write here
      # would be a second contact rather than an edit of the first,
      # there being no id in the file to recognise it by, so the POST
      # over a stored row is that row's own editor's Save instead —
      # the same amend the contact's own page writes (#apply_edit),
      # landing back on the row's read screen.
      stored = saved[index.to_s]
      contact = stored ? store.contact(stored) : nil
      if contact
        return apply_edit(r, contact.id,
                          refuse: ->(fresh, notice:) { edit_card_screen(r, upload, index, contact: fresh, notice:) },
                          land: "/import/#{upload}/#{index}")
      end

      # A card being folded into a contact the book already has
      # (#card_screen's `into`), the fold derived again here rather
      # than trusted from the page, and refused outright if the
      # contact is gone (docs/plans/2026-09-23-merging-on-import.md,
      # "The Save").
      into = r.params["into"].to_s
      target = into.empty? ? nil : store.contact(into)
      if !into.empty? && target.nil?
        return card_screen(upload, index, notice: "The contact this card was updating is gone; nothing was saved.")
      end

      merge = target && Import::Merge.new(target, card)
      contact = merge ? merge.contact : import_contact(card, index)
      # Which toggle the refusals below re-render under.
      into = target ? target.id : ""

      # The groups ride in the same form and are written by the same
      # Save (Admin::ImportGroups). Only ids naming a group, and `was`,
      # are #apply_groups' own; the boxes are the whole answer, the
      # group for the import included, and a ticked name is made by
      # the write (Import::Write#group_id). Read before the refusals,
      # so a card sent back comes back with its boxes as they were
      # ticked (the plan's "Writing them in").
      choices = store.group_choices
      known = choices.map(&:id)
      ticked = ids_in(r.params["groups"]) & known
      was = ids_in(r.params["was"]) & known
      wanted = ids_in(r.params["named"]).map(&:strip).reject(&:empty?)
      # Everyone's book, which may not exist yet to tick, rides as an
      # answer rather than an id (Import::Write.call's `everyone`).
      everyone = choices.find { it.name == Group::EVERYONE }
      syncing = everyone.nil? || ticked.include?(everyone.id)

      # A blank name is refused, #apply_edit's check.
      first = r.params["first"].to_s.strip
      middle = r.params["middle"].to_s.strip
      last = r.params["last"].to_s.strip
      if Admin::CardForm.nameless?(contact, r.params)
        return card_screen(upload, index, into:, notice: "A contact needs a name.", joined: ticked, named: wanted)
      end

      fields = r.params["birthday"]
      birthday =
        if fields.is_a?(Hash)
          begin
            Admin::CardForm.birthday(fields)
          rescue ArgumentError
            return card_screen(upload, index, into:, notice: "That birthday is not a shape a date can take.",
                                              joined: ticked, named: wanted)
          end
        else
          contact.birthday
        end

      # The snapshot guard the editor always carries, over the staged
      # card rather than a stored one: two tabs open on the same
      # import are the case, and applying this save over the other
      # one's would revert it. Over a fold, it is the contact's own
      # guard too.
      if r.params["etag"].to_s != contact.etag
        return card_screen(upload, index, into:, notice: "This card changed since the page loaded; nothing was saved.",
                                          joined: ticked, named: wanted)
      end

      edited = Admin::CardForm.contact_card(contact, first, middle, last, r.params)
      if target
        # A stored contact, whose birthday the model holds: the contact
        # editor's own save (#apply_edit), down to its one refusal.
        if birthday && carries_own_bday?(contact)
          return card_screen(upload, index, into:,
                             notice: "This contact's card carries its own birthday spelling; nothing was saved.",
                             joined: ticked, named: wanted)
        end

        written = span("import.write") {
          Import::Write.update(store, target.id, edited, birthday:, joins: ticked - was, leaves: was - ticked, named: wanted)
        }
        # Staged after the write, unlike a new contact's below
        # (docs/plans/2026-09-23-merging-on-import.md, "The Save").
        revised[index] = edited
        span("import.restage") { Import::Staged.update(upload, joined(revised)) }
        return walk_on(r, upload, index, written, saved, revised)
      end

      # The birthday goes back into the card, an import having no
      # model to hold one until it is written. Skipped for a card carrying
      # a BDAY spelling the model does not read: that line stayed in
      # the card (#import_contact, Store#put's own rule), no row
      # rendered for it, and a replace here would delete it.
      unless carries_own_bday?(contact)
        line = birthday&.to_line
        # A birthday no vCard 3.0 card can spell is refused rather
        # than lost, a staged contact being only its card
        # (docs/plans/2026-09-21-import-a-vcf.md, "The walk").
        if birthday && line.nil?
          return card_screen(upload, index,
                             notice: "A card cannot hold a birthday that partial. Import the contact, then add the date on its own page.",
                             joined: ticked, named: wanted)
        end

        edited = edited.replace("BDAY", line ? [line] : [])
      end

      # Staged before it is stored, and kept afterwards: the list
      # renders every row from these bytes, so a row that has come in
      # is still a row the list has to be able to name.
      revised[index] = edited
      span("import.restage") { Import::Staged.update(upload, joined(revised)) }
      written = span("import.write") { Import::Write.call(store, edited, joins: ticked, named: wanted, everyone: syncing) }
      walk_on(r, upload, index, written, saved, revised)
    end

    # A row's Save landed, as a new contact or an updated one: the row
    # noted as saved, and the walk on from it. `saved` is the rows
    # saved before this one, and `revised` the file's cards with this
    # row's save staged among them.
    #: (untyped r, String upload, Integer index, Contact written, Hash[String, String] saved, Array[VCard] revised) -> untyped
    def walk_on(r, upload, index, written, saved, revised)
      Import::Staged.record(upload, index.to_s, written.id)

      # The last one: there is nothing left to come back to, so the
      # walk is over rather than a list of rows that all say the same
      # thing.
      return close_walk(r, upload) if saved.length + 1 == revised.length

      # Onto the next row still to save below this one, in the list's
      # order (#walk_order). Below rather than first, so a row
      # passed over stays passed over: skipping one is opening the
      # next, and the walk comes back round to it only once the rows
      # after it are saved. `saved` was read before this write, so the
      # row just written is named here too; a `fetch` rather than a
      # `first` because empty is the case the line above took, and
      # reaching it is a broken assumption rather than a screen to
      # render.
      order = walk_order(import_contacts(revised))
      remaining = order.reject { |i| saved.key?(i.to_s) || i == index }
      below = order.drop(order.index(index).to_i + 1)
      r.redirect "/import/#{upload}/#{below.find { remaining.include?(it) } || remaining.fetch(0)}", 303
    end

    # The end of the walk, reached only by saving the last card there
    # was to save: the file and the walk's own notes gone, and the
    # group the import filed under standing where the walk stood — or
    # the whole book, for a walk whose every card left that group
    # (docs/plans/2026-09-21-import-a-vcf.md, "Nothing waits for the
    # end").
    #: (untyped r, String upload) -> untyped
    def close_walk(r, upload)
      return expired_screen if Import::Staged.read(upload, Import::Staged::SAVED).nil?

      group, _saved = Import::Staged.saved(upload)
      Import::Staged.close(upload)
      filed = store.group_choices.find { it.name == group }

      r.redirect(filed ? "/groups/#{filed.id}" : "/contacts", 303)
    end

    # The import's two readings, or none when it is gone
    # (Import::Staged.read).
    #
    # The re-read parses files this already parsed, which is not a
    # second judgment of them: the bytes are what was staged, and this
    # is the only way back to the cards. A file that read on the way
    # in and will not read now is a broken assumption and raises.
    #: (String upload) -> [Array[VCard], Array[VCard]]?
    def staged_cards(upload)
      original = Import::Staged.read(upload, Import::Staged::ORIGINAL)
      revised = Import::Staged.read(upload, Import::Staged::REVISED)
      return nil if original.nil? || revised.nil?

      span("import.staged") { |step|
        step.set_attribute("bytes", original.bytesize + revised.bytesize)
        cards = [Import::Vcf.cards(original), Import::Vcf.cards(revised)] #: [Array[VCard], Array[VCard]]
        step.set_attribute("cards", cards[0].length)
        cards
      }
    end

    # A staged card read as the contact the editor edits. The id is
    # its place in the file, there being no minted one until it is
    # written, and no group lends a card that is not stored yet a
    # line.
    #
    # The birthday comes out of the card and into the model, Store#put's
    # split and its rule for a BDAY the model does not read, so the
    # editor renders the same row over an import as over a contact.
    #: (VCard card, Integer index) -> Contact
    def import_contact(card, index)
      bdays, rest = card.extract("BDAY")
      birthday = bdays.filter_map { it.property }.filter_map { Birthday.from_property(it) }.first
      Contact.new(id: index.to_s, stored: birthday ? rest : card, birthday:, inherited: [])
    end

    # Every staged card as #import_contact reads it, in file order.
    #: (Array[VCard] revised) -> Array[Contact]
    def import_contacts(revised)
      revised.each_with_index.map { |card, index| import_contact(card, index) }
    end

    #: (Contact contact) -> bool
    def carries_own_bday?(contact)
      contact.stored.lines.any? { it.names?("BDAY") }
    end

    # Cards back into a file, each keeping its own bytes. A break
    # after any that did not carry one: a file whose last card ends
    # without a newline is still a file, and two cards glued at
    # END:VCARDBEGIN:VCARD is not.
    #: (Array[VCard] cards) -> String
    def joined(cards)
      cards.map { |card|
        bytes = card.to_s
        bytes.end_with?("\n") ? bytes : "#{bytes}\r\n"
      }.join
    end

    # The file part the form sent, and none for a POST carrying no
    # file: #ids_in's shape over an upload, and its reason for being a
    # method — the empty case needs a type, and the signature is where
    # one fits.
    #: (untyped param) -> untyped
    def file_in(param)
      param if param.is_a?(Hash) && param[:tempfile]
    end

    # The screen a file is chosen on, which is all this path is: a
    # walk that has ended has a group to land on rather than a page
    # here saying it ended (#close_walk).
    #: (?notice: String?) -> String
    def import_screen(notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::ImportUpload.call(login: @login, notice:)
    end

    #: () -> String
    def expired_screen
      import_screen(notice: "That import is no longer here. Choose the file again.")
    end
  end
end
