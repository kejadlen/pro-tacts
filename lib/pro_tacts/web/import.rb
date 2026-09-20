require "pro_tacts/admin/plan_upload"
require "pro_tacts/import/card"
require "pro_tacts/import/land"

module ProTacts
  class Web < Roda
    # The import screen: a plan's cards arrive as an upload and land in
    # this server's store (docs/plans/2026-09-20-import-by-upload.md).
    # It replaces `rake import:execute`, which carried the same cards
    # over HTTP from the machine the plan sat on — the routes it drove
    # are still there, and nothing here is a second way to write a
    # card: Import::Land goes through Store#put and Store#regroup, the
    # two writes that PUT and the groups dialog make.
    #
    # Under the same identity gate as every other route (web.rb), which
    # is also where the cards' books come from: a card this creates
    # joins everyone's book the way a client's create does, so the
    # person importing does not have to be the person syncing.
    hash_branch("import") do |r|
      r.is do
        r.get do
          plan_upload_screen
        end

        r.post do
          apply_import(r)
        end
      end
    end

    private

    # The upload's whole POST, #apply_edit's shape: the request's own
    # validity first — every file named and read before anything is
    # written, `execute`'s rule that a card which will not read stops
    # the run with nothing landed — and the write after it.
    #
    # It answers with the result rather than the 303 the other writes
    # answer with, and can afford to: landing is idempotent, so the
    # re-submission a back button offers writes nothing, and there is
    # no other page that holds what just arrived.
    #: (untyped r) -> String
    def apply_import(r)
      uploads = r.params["cards"]
      uploads = uploads.is_a?(Array) ? uploads.select { it.is_a?(Hash) && it[:tempfile] } : []
      return plan_upload_screen(notice: "Choose the card files in a plan's cards directory.") if uploads.empty?

      cards = {} #: Hash[String, Import::Card]
      uploads.each do |upload|
        # The browser sends a basename; File.basename is against a
        # client that sends more than one.
        name = File.basename(upload[:filename].to_s)
        id = name.delete_suffix(".yml")
        unless name.end_with?(".yml") && id.match?(Contact::ID_FORMAT)
          return plan_upload_screen(notice: "#{name} is not a plan card: a card file is named for the id it lands under.")
        end

        # Relabelled and judged in the same breath, Web#write_card's
        # rule for the one other body this app reads: a multipart part
        # arrives as binary, and a force_encoding nobody validates is a
        # lie every later reader inherits — here it would surface as a
        # 500 out of SQLite on the insert, past the point where the
        # person could be told which file was wrong.
        bytes = upload.fetch(:tempfile).read.force_encoding(Encoding::UTF_8)
        return plan_upload_screen(notice: "#{name} is not UTF-8 text.") unless bytes.valid_encoding?

        begin
          cards[id] = Import::Card.parse(bytes, name)
        rescue Import::Card::Invalid => error
          return plan_upload_screen(notice: error.message)
        end
      end

      plan_upload_screen(arrivals: Import::Land.call(store, cards))
    end

    #: (?arrivals: Array[Import::Land::Arrival]?, ?notice: String?) -> String
    def plan_upload_screen(arrivals: nil, notice: nil)
      response["Content-Type"] = "text/html; charset=utf-8"
      Admin::PlanUpload.call(arrivals:, notice:)
    end
  end
end
