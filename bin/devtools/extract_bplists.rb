#!/usr/bin/env ruby
# Development tool to extract and convert binary plist payload data from messages database to YAML files

require 'sqlite3'
require 'yaml'
require 'open3'
require 'plist'

# Connect to the database
db = SQLite3::Database.new(File.expand_path("~/Library/Messages/chat.db"))

# Get all rows with payload_data
rows = db.execute("SELECT rowid, payload_data FROM message WHERE payload_data IS NOT NULL ORDER BY date DESC")

puts "Processing #{rows.length} records..."

rows.each do |row|
  rowid, payload_data = row

  begin
    # Convert binary plist to XML using plutil
    stdout, _, status = Open3.capture3("plutil -convert xml1 - -o -", stdin_data: payload_data, binmode: true)

    next print("E") unless status.success?
    print(".")

    # Parse XML plist
    parsed_data = Plist.parse_xml(stdout)

    # Write to YAML file
    File.write("dat/bplists/#{rowid}.yaml", parsed_data.to_yaml)

  rescue => e
    puts "Error processing rowid #{rowid}: #{e.message}"
  end
end

puts "Done."
