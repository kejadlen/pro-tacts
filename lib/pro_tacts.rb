# frozen_string_literal: true

require "pro_tacts/config"

module ProTacts
  class << self
    def config
      @config ||= Config.new
    end

    attr_writer :config
  end
end
