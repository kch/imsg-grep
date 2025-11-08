#!/usr/bin/env ruby
# Development tool to extract attributedBody data from messages database to binary files

require 'sqlite3'

# Connect to the database
db = SQLite3::Database.new(File.expand_path("~/Library/Messages/chat.db"))

# Get all rows with attributedBody (or row ids from argv)
rowid_cond = ARGV.empty? ? "" : "AND rowid IN (#{ARGV.join(",")})"
rows = db.execute("SELECT rowid, attributedBody FROM message
  WHERE
    attributedBody IS NOT NULL
    #{rowid_cond}
    ORDER BY rowid")

puts "Processing #{rows.length} records..."

rows.each do |row|
  rowid, attributed_body = row

  begin
    # Write binary data to file
    File.binwrite("dat/attr_bodies/#{rowid}.bin", attributed_body)
    print(".")
  rescue => e
    puts "Error processing rowid #{rowid}: #{e.message}"
  end
end

puts "Done."
