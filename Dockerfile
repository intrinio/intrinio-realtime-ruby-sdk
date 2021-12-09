FROM ruby:2.7.5

RUN mkdir /intrinio

WORKDIR /intrinio

COPY . /intrinio

RUN bundle install

CMD RUBYOPT=-W0 bundle exec ruby sample/simple.rb