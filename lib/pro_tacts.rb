
require "fileutils"

require "pro_tacts/config"

module ProTacts
  class << self
    def config
      @config ||= Config.new
    end

    attr_writer :config

    # Called from config.ru rather than at require time, so loading the
    # app stays side-effect free. A fresh checkout has no contacts dir;
    # an empty address book beats a 500 on every request.
    def ensure_data_directories
      FileUtils.mkdir_p(config.contacts_dir)
    end
  end
end
