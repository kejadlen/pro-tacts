# frozen_string_literal: true

require "minitest/autorun"
require "rack/test"

require "roda/plugins/dav_verbs"

class DavVerbsTest < Minitest::Test
  include Rack::Test::Methods

  class App < Roda
    plugin :dav_verbs

    route do |r|
      r.propfind do
        "propfind"
      end

      r.report do
        "report"
      end
    end
  end

  def app
    App
  end

  def test_propfind
    request "/", method: "PROPFIND"

    assert_equal 200, last_response.status
    assert_equal "propfind", last_response.body
  end

  def test_report
    request "/", method: "REPORT"

    assert_equal 200, last_response.status
    assert_equal "report", last_response.body
  end
end
