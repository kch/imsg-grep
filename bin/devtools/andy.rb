#!/usr/bin/env ruby
# Development tool to query messages with 'andy' in participant details and YouTube/SoundCloud links

require_relative "../../lib/messages"

# Create temp view for chat names keyed by message_id
$db.execute <<~SQL
  CREATE TEMP VIEW message_chat_names AS
  SELECT
    m.ROWID as message_id,
    c.display_name,
    CASE
      WHEN c.ROWID IS NOT NULL AND c.style != 0 AND json_array_length(md.participant_handles) > 2 THEN
        COALESCE(
          NULLIF(c.display_name, ''),
          (SELECT group_concat(
            COALESCE(
              json_extract(cd.contact, '$.name'),
              value
            ), ', '
          )
          FROM json_each(md.participant_handles)
          LEFT JOIN contact_details cd ON cd.handle = value)
        )
      ELSE NULL
    END as name
  FROM messages_db.message m
  LEFT JOIN messages_db.chat_message_join cm ON m.ROWID = cm.message_id
  LEFT JOIN messages_db.chat c ON cm.chat_id = c.ROWID
  LEFT JOIN messages_decoded md ON m.ROWID = md.id
SQL

# Query for messages with 'andy' in participant details and YouTube links in payload
$db.results_as_hash = true
andy_youtube_results = $db.execute(<<~SQL)
  SELECT
    m.id,
    m.utc_time,
    m.sender_handle,
    COALESCE(json_extract(m.sender_details, '$.name'), m.sender_handle) as sender_name,
    mcn.name as chat_name,
    mcn.display_name,
    m.participant_details,
    json_extract(m.payload, '$.richLinkMetadata.title') as title,
    json_extract(m.payload, '$.richLinkMetadata.summary') as summary,
    json_extract(m.payload, '$.richLinkMetadata.URL') as url
  FROM messages m
  LEFT JOIN message_chat_names mcn ON m.id = mcn.message_id
  WHERE
    EXISTS (
      -- Match 'andy' only in JSON leaf string values, not keys
      SELECT 1 FROM json_tree(m.participant_details)
      WHERE type = 'text'
      AND LOWER(value) LIKE '%andy%'
    )
    AND m.payload IS NOT NULL
    AND (json_extract(m.payload, '$.richLinkMetadata.URL') LIKE '%youtube%' OR json_extract(m.payload, '$.richLinkMetadata.URL') LIKE '%soundcloud%')
    AND m.is_from_me = 0
  ORDER BY m.utc_time DESC
  LIMIT 20
SQL

require 'rainbow'
def ¢(...) = Rainbow(...)

puts "Found #{andy_youtube_results.size} messages with 'andy' and YouTube links:"
andy_youtube_results.each do |row|
  row.transform_keys(&:to_sym) => {id:, utc_time:, sender_name:, chat_name:, display_name:, title:, summary:, url:}
  chat_prefix = (display_name && !display_name.empty?) ? "via" : "with"
  from_text = chat_name ? "#{sender_name} (#{chat_prefix} #{chat_name})" : sender_name
  puts ¢("ID: "     ).bright.magenta + ¢(id).bright.cyan + ¢(", Time: ").bright.magenta + ¢(utc_time).bright.white + ¢(", From: ").bright.magenta + ¢(from_text).bright.blue
  puts ¢("Title: "  ).bright.yellow  + ¢(title).gold
  puts ¢("Summary: ").bright.green   + ¢(summary).lime
  puts ¢("URL: "    ).bright.red     + ¢(url).aqua
  puts ¢("---"      ).gray
end
