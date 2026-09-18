FROM ruby:4.0-slim AS build

RUN apt-get update && apt-get install -y build-essential && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set without development && bundle install

COPY . .

FROM ruby:4.0-slim

# The image's own tag, and the release's name (see ci.yml) — the one
# build fact the app reads back out, in the admin footer. It carries the
# build time and the short sha, so nothing else about the build has to
# be passed in beside it.
ARG VERSION
ENV VERSION=${VERSION}
# rackup defaults to development, which wraps the app in Rack::Lint and
# ShowExceptions.
ENV RACK_ENV=production
# Set TZ at runtime — Date.today drives the birthday list's rollover.

# git, for the dump `rake console` commits before its prompt
# (tasks/console.rake): a mistake at the prompt is then a revert in
# the dump's repository rather than a restore from backup.
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

EXPOSE 9292

# 0.0.0.0 reaches only the container's own network namespace — exposure
# to clients is tailscale serve's job, in front of the published port.
CMD ["rackup", "-o", "0.0.0.0"]
