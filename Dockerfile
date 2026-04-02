ARG ERLANG_VERSION=28.4.1.0
ARG GLEAM_VERSION=v1.15.2

# Gleam stage
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-scratch AS gleam

# Build stage
FROM erlang:${ERLANG_VERSION}-alpine AS build
# Add git so we can fetch the fork. This is temporary
RUN apk add --no-cache git
COPY --from=gleam /bin/gleam /bin/gleam
COPY . /app/
RUN cd /app && gleam export erlang-shipment

# Final stage
FROM erlang:${ERLANG_VERSION}-alpine
ARG GIT_SHA
ARG BUILD_TIME
ENV GIT_SHA=${GIT_SHA}
ENV BUILD_TIME=${BUILD_TIME}
COPY --from=build /app/build/erlang-shipment /app
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
