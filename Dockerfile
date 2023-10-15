FROM ruby:3.1.2-alpine3.16

WORKDIR /app

RUN apk --update add --no-cache --virtual run-dependencies \
    build-base

COPY Gemfile Gemfile.lock /app/

RUN bundle install --jobs 4 --retry 3

COPY . .

EXPOSE 4000

CMD ["bundle", "exec", "jekyll", "serve", "-H", "0.0.0.0"]
