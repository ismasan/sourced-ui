# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in sourced-ui.gemspec
gemspec

gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

# gem 'sourced', github: 'ismasan/sourced', branch: 'statecharts'
gem 'sourced', path: '../sourced'
# gem 'sidereal', github: 'ismasan/sidereal' #path: '/Users/ismasan/code/personal/gems/sidereal'
gem 'sidereal', path: '../sidereal'

gem 'docco', github: 'ismasan/docco'

group :test do
  gem 'debug'
  gem 'nokogiri'
  gem 'rack-test'
  gem 'sequel'
  gem 'sqlite3'
end
