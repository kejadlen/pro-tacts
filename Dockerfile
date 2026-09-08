FROM ruby:4.0-slim AS build

RUN apt-get update && apt-get install -y build-essential && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set without development && bundle install

COPY . .

FROM ruby:4.0-slim

ARG COMMIT_SHA
ARG CHANGE_ID
ARG BUILD_DATE
# The image's own tag, and the release's name (see ci.yml) — the one
# build fact the app reads back out, in the admin footer.
ARG VERSION
ENV COMMIT_SHA=${COMMIT_SHA}
ENV CHANGE_ID=${CHANGE_ID}
ENV BUILD_DATE=${BUILD_DATE}
ENV VERSION=${VERSION}
# Set TZ at runtime — Date.today drives the birthday list's rollover.

WORKDIR /app

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

EXPOSE 9292

# 0.0.0.0 reaches only the container's own network namespace — exposure
# to clients is tailscale serve's job, in front of the published port.
CMD ["rackup", "-o", "0.0.0.0"]
