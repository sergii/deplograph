FROM ruby:4.0.10-slim

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential libpq-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /rails
COPY Gemfile .ruby-version ./
RUN bundle install
COPY . .

ENV RAILS_ENV=production
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
