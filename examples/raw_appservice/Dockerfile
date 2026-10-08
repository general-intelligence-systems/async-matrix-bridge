FROM ruby:3.4-slim AS build

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       build-essential libssl-dev pkg-config curl git \
  && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.cargo/bin:$PATH"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain stable

COPY lib /gem/lib
COPY async-matrix-bridge.gemspec LICENSE README.md /gem/

WORKDIR /app

COPY examples/raw_appservice/Gemfile ./
RUN bundle install && rm -rf /usr/local/bundle/cache

FROM ruby:3.4-slim

COPY --from=build /gem /gem
COPY --from=build /usr/local/bundle /usr/local/bundle

WORKDIR /app

COPY --from=build /app/Gemfile /app/Gemfile.lock ./
COPY examples/raw_appservice/appservice.rb ./

EXPOSE 9001
CMD ["ruby", "appservice.rb"]
