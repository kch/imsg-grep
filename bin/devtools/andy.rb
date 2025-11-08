#!/usr/bin/env ruby
# Development tool to query messages with 'andy' in participant details and YouTube/SoundCloud links

require_relative "../../lib/messages"

# Query for messages with 'andy' in participant details and YouTube links in payload
$db.results_as_hash = true
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
def ¢(...) = Rainbow(...)

puts "Found #{andy_youtube_results.size} messages with 'andy' and YouTube links:"
andy_youtube_results.each do |row|
  row.transform_keys(&:to_sym) => {id:, utc_time:, sender_name:, chat_name:, chat_style:,  title:, summary:, url:}
  from_text = chat_name && chat_style != 0 ? "#{sender_name} (via #{chat_name})" : sender_name
  puts ¢("ID: "     ).bright.magenta + ¢(id).bright.cyan + ¢(", Time: ").bright.magenta + ¢(utc_time).bright.white + ¢(", From: ").bright.magenta + ¢(from_text).bright.blue
  puts ¢("Title: "  ).bright.yellow  + ¢(title).gold
  puts ¢("Summary: ").bright.green   + ¢(summary).lime
  puts ¢("URL: "    ).bright.red     + ¢(url).aqua
  puts ¢("---"      ).gray
end
