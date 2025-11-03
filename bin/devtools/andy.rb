#!/usr/bin/env ruby
# Development tool to query messages with 'andy' in participant details and YouTube/SoundCloud links

require_relative "../../lib/messages"

# Query for messages with 'andy' in participant details and YouTube links in payload
andy_youtube_results = $db.execute(<<~SQL)
  SELECT
    id,
    utc_time,
    sender_handle,
    COALESCE(json_extract(sender_details, '$.name'), sender_handle) as sender_name,
    chat_name,
    chat_style,
    participant_details,
    json_extract(payload, '$.richLinkMetadata.title') as title,
    json_extract(payload, '$.richLinkMetadata.summary') as summary,
    json_extract(payload, '$.richLinkMetadata.URL') as url
  FROM messages
  WHERE
    EXISTS (
      -- Match 'andy' only in JSON leaf string values, not keys
      SELECT 1 FROM json_tree(participant_details)
      WHERE type = 'text'
      AND LOWER(value) LIKE '%andy%'
    )
    AND payload IS NOT NULL
    AND (json_extract(payload, '$.richLinkMetadata.URL') LIKE '%youtube%' OR json_extract(payload, '$.richLinkMetadata.URL') LIKE '%soundcloud%')
    AND is_from_me = 0
  ORDER BY utc_time DESC
  LIMIT 20
SQL

require 'rainbow'

puts "Found #{andy_youtube_results.size} messages with 'andy' and YouTube links:"
andy_youtube_results.each do |row|
  from_text = row[5] && row[6] != 0 ? "#{row[3]} (via #{row[4]})" : row[3]  # chat_name, chat_style
  puts Rainbow("ID: ").bright.magenta + Rainbow("#{row[0]}").bright.cyan + Rainbow(", Time: ").bright.magenta + Rainbow("#{row[1]}").bright.white + Rainbow(", From: ").bright.magenta + Rainbow(from_text).bright.blue
  puts Rainbow("Title: ").bright.yellow + Rainbow("#{row[7]}").gold
  puts Rainbow("Summary: ").bright.green + Rainbow("#{row[8]}").lime
  puts Rainbow("URL: ").bright.red + Rainbow("#{row[9]}").aqua
  puts Rainbow("---").gray
end
