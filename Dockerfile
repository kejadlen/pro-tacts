# The Ruby both stages build on. A release also builds this file on
# rubylang/ruby:master-noble, Ruby HEAD as the core team builds it every
# few hours, configured with --enable-zjit (see ci.yml's build-head).
ARG RUBY_IMAGE=ruby:4.0-slim

FROM ${RUBY_IMAGE} AS build

# The official image's own gem layout, restated for a base that has
# none: rubylang/ruby installs gems beside Ruby and keeps bundle config
# in ~/.bundle, neither of which the runtime stage copies.
ENV GEM_HOME=/usr/local/bundle BUNDLE_APP_CONFIG=/usr/local/bundle BUNDLE_SILENCE_ROOT_WARNING=1

# pkg-config, patch and zlib, for the HEAD build: no precompiled
# nokogiri, sqlite3 or google-protobuf is cut for an unreleased Ruby, so
# its bundle compiles them from source.
RUN apt-get update && apt-get install -y build-essential pkg-config patch zlib1g-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set without development && bundle install

COPY . .

# On HEAD the install above compiled the native gems from source and
# rewrote the lock to what it installed; COPY then restored the
# repository's lock, pinning precompiled variants the image does not
# carry, and `bundle exec` in the container (the console task execs
# one) resolves against the lock. Install again off the restored lock
# so it agrees with the installed set; on a released Ruby this is a
# verifying no-op.
RUN bundle install

FROM ${RUBY_IMAGE}

ENV GEM_HOME=/usr/local/bundle BUNDLE_APP_CONFIG=/usr/local/bundle BUNDLE_SILENCE_ROOT_WARNING=1
ENV PATH=/usr/local/bundle/bin:$PATH

# The image's own tag, and the release's name (see ci.yml) — the one
# build fact the app reads back out, in the admin footer. It carries the
# build time and the short sha, so nothing else about the build has to
# be passed in beside it.
ARG VERSION
ENV VERSION=${VERSION}
# rackup defaults to development, which wraps the app in Rack::Lint and
# ShowExceptions.
ENV RACK_ENV=production
# Empty but for the HEAD build, which passes --zjit so the app runs
# under ZJIT without anyone having to ask for it.
ARG RUBYOPT
ENV RUBYOPT=${RUBYOPT}
# Set TZ at runtime — Date.today drives the birthday list's rollover.

# git, for the commit `rake db:dump` makes of what it wrote
# (tasks/db.rake): a snapshot is then something to revert to rather
# than the last one overwritten.
RUN apt-get update && apt-get install -y git libjemalloc2 && rm -rf /var/lib/apt/lists/*

# jemalloc in place of glibc's malloc, which keeps what a request
# freed and spreads it over an arena per request thread, so a server
# that has drawn a few big pages rests near its peak. Two arenas, and a
# background thread handing back what has gone unused for a second, so
# it rests near what it holds instead
# (docs/plans/2026-10-15-resting-memory.md). Named by soname, which the
# loader finds on either architecture's library path.
ENV LD_PRELOAD=libjemalloc.so.2
ENV MALLOC_CONF=narenas:2,background_thread:true,dirty_decay_ms:1000,muzzy_decay_ms:0

WORKDIR /app

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

# An image tagged for ZJIT checks it really has it, rather than trusting
# the base was configured with it.
RUN case "$RUBYOPT" in *--zjit*) ruby -e 'abort "ZJIT is off" unless defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?' ;; esac

EXPOSE 9292

# 0.0.0.0 reaches only the container's own network namespace. Exposure to
# clients is the proxy's job (ProxyAuth): publish the port on localhost
# alone (-p 127.0.0.1:9292:9292), because reached directly the app trusts
# whatever Remote-User it is handed.
CMD ["rackup", "-o", "0.0.0.0"]
