# What a `rake console` session loads: the app's store half and one
# already open on the configured database, so the session starts ready
# for the operations no screen has — `store.contacts`,
# `store.delete(id)`, `store.delete_group(id)`. PRO_TACTS_DATABASE
# points it at another database, the same way the tasks under tasks/
# are pointed. A method rather than a local because a required file
# cannot set the session's own.
require "pro_tacts"
require "pro_tacts/store"

def store
  @store ||= ProTacts::Store.at(ProTacts.config.database_path)
end
