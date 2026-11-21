# Synthetic fixture, not a runnable image definition.
FROM ruby:4.0.10-slim AS builder
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install
FROM ruby:4.0.10-slim
WORKDIR /app
COPY --from=builder /app /app
CMD ["ruby", "-v"]
