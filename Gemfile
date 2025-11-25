source "https://rubygems.org"

if File.directory?("../strop")
  gem "strop", path: "../strop"
else
  gem "strop"
end

gem "sqlite3"
gem "base64" # builtin

group :development do
  gem "debug"    # builtin
  gem "minitest" # builtin
  gem "rainbow"
  gem "plist"
end
