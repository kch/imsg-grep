source "https://rubygems.org"

gem "base64" # builtin
gem "sqlite3"
gem "rainbow"

if File.directory?("../strop")
  gem "strop", path: "../strop"
else
  gem "strop"
end

group :development do
  gem "debug"    # builtin
  gem "minitest" # builtin
  gem "plist"
end
