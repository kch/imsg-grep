#!/usr/bin/env ruby
# frozen_string_literal: true
# Core iMessage database processing - builds views with decoded messages, expanded contacts, a cache

require 'sqlite3'
require 'fileutils'
require_relative 'apple/keyed_archive'
require_relative 'apple/attr_str'

module Messages
  APPLE_EPOCH = 978307200

  ADDY_DB  = Dir[File.expand_path("~/Library/Application Support/AddressBook/Sources/*/AddressBook-*.abcddb")][0]
  IMSG_DB  = File.expand_path("~/Library/Messages/chat.db")
  CACHE_DB = File.expand_path("~/.cache/imsg-grep/cache.db")

  def self.reset_cache = FileUtils.rm_f(CACHE_DB)
  def self.db = @db

  def self.init
    ################################################################################
    ### DB Setup ###################################################################
    ################################################################################
    FileUtils.mkdir_p File.dirname(CACHE_DB)
    FileUtils.touch(CACHE_DB)

    [ADDY_DB, IMSG_DB, CACHE_DB].each do |db|
      raise "Database not found: #{db}" unless File.exist?(db)
      raise "Database not readable: #{db}" unless File.readable?(db)
    end

    @db = SQLite3::Database.new(":memory:")
    @db.execute "ATTACH DATABASE '#{ADDY_DB}' AS _addy"
    @db.execute "ATTACH DATABASE '#{IMSG_DB}' AS _imsg"
    @db.execute "ATTACH DATABASE '#{CACHE_DB}' AS _cache"

    def @db.select_hashes(sql) = prepare(sql).execute.enum_for(:each_hash).map{ it.transform_keys(&:to_sym) }
    def @db.ƒ(f, &) = define_function_with_flags(f.to_s, SQLite3::Constants::TextRep::UTF8 | SQLite3::Constants::TextRep::DETERMINISTIC, &)

    regex_cache = Hash.new { |h,src| h[src] = Regexp.new(src) }
    @db.ƒ(:regexp)           { |rx, text| regex_cache[rx].match?(text) ? 1 : 0 }
    @db.ƒ(:apple2unix)       { |time| (time / 1_000_000_000) + APPLE_EPOCH }
    @db.ƒ(:unarchive_keyed)  { |data| KeyedArchive.unarchive(data).to_json if data }
    @db.ƒ(:unarchive_string) { |data| AttributedStringExtractor.extract(data) if data }
    # othan than regexp, the simpler versions above are no longer used because caching, but useful when doing other sql stuff

    ################################################################################
    ### Contacts/handles setup #####################################################
    ################################################################################
    # Contacts table with:
    # - contact_id: id in address book
    # - handle_id: handle.rowid in chat.db
    # - handle: email or phone number (formatted as handle)
    # - is_me: (unused atm)
    # one row per handle.
    # only contacts that exist in chat.db, but all handles even those not in chat.db
    # so can be used when matching contact info
    @db.ƒ(:normalize_phone) { |text| text =~ /[^\p{Punct}\p{Space}\d+]/ ? text : text.delete("^0-9+") } # remove punctuation from normal phones but keep weird phones intact
    @db.execute <<~SQL
      CREATE TEMP TABLE contacts AS
      WITH contact_handles AS ( -- handles from _addy per contact_id
        SELECT
          ZOWNER   as contact_id,
          ZADDRESS as handle
        FROM _addy.ZABCDEMAILADDRESS
        UNION ALL
        SELECT
          ZOWNER as contact_id,
          normalize_phone(ZFULLNUMBER) as handle
        FROM _addy.ZABCDPHONENUMBER
      ),
      matched_handles AS ( -- handles from _addy for matched handles in _imsg
        SELECT DISTINCT
          r.Z_PK    as contact_id,
          ih.ROWID  as handle_id,
          ch.handle as matched_handle,
          (r.ZCONTAINERWHERECONTACTISME IS NOT NULL) as is_me
        FROM _addy.ZABCDRECORD r
        JOIN contact_handles ch ON r.Z_PK = ch.contact_id
        JOIN _imsg.handle ih    ON ih.id = ch.handle                 -- only handles in _imsg
      )
      SELECT
        mh.contact_id,
        mh.handle_id,
        ch.handle,                                                   -- all handles for this contact
        mh.is_me
      FROM matched_handles mh
      JOIN contact_handles ch ON ch.contact_id = mh.contact_id       -- get ALL handles for matched contact
    SQL

    @db.ƒ(:computed_name) do |first, maiden, middle, last, nick, org|
      names = [first, maiden, middle, last].compact.reject(&:empty?)
      names << "(#{nick})" if nick && !nick.empty?
      names.empty? ? org.to_s : names.join(" ")
    end

    # Handle groups table:
    # - handle_id: handle.rowid in chat.db
    # - searchable: JSON array of searchable terms: handles + names
    # - name: contact display name computed from address book
    # - contact_ids: JSON array of contact IDs from address book (unused atm)
    # one row per handle_id. includes handles without contact entries
    @db.execute <<~SQL
      CREATE TEMP TABLE handle_groups AS
      WITH computed AS (
        SELECT
          c.handle_id,
          computed_name(r.zfirstname, r.zmaidenname, r.zmiddlename, r.zlastname, r.znickname, r.zorganization)
            as name,
          r.Z_PK as contact_id
        FROM _addy.zabcdrecord r
        JOIN contacts c ON c.contact_id = r.Z_PK                  -- get all contact->handle mappings with computed names
      ),
      searchables AS (
        SELECT c.handle_id, c2.handle as term                     -- get ALL handles for this contact
        FROM computed c
        JOIN contacts c2 ON c2.contact_id = c.contact_id
        UNION ALL
        SELECT handle_id, name as term                            -- flatten: handle_id -> each computed name
        FROM computed
      )
      SELECT
        c.handle_id,
        ( SELECT json_group_array(DISTINCT term)                  -- collect all searchable terms per handle
          FROM searchables s
          WHERE s.handle_id = c.handle_id) as searchable,         -- result: ["handle1","handle2","Name"]
        MIN(c.name) as name,                                      -- pick first computed name when duplicates
        json_group_array(DISTINCT c.contact_id) as contact_ids    -- collect all contact_ids as JSON array
      FROM computed c
      GROUP BY c.handle_id                                        -- collapse duplicate contact entries per handle
      UNION
      SELECT -- add handles without any contact entry
        h.ROWID as handle_id,
        json_array(h.id) as searchable,                           -- only handle is searchable
        h.id as name,                                             -- handle as display name
        null as contact_ids                                       -- no contacts for this handle
      FROM _imsg.handle h
      WHERE h.ROWID NOT IN (SELECT handle_id FROM contacts)      -- exclude handles already processed above
      ORDER BY name
    SQL

    ################################################################################
    ### Caching ####################################################################
    ################################################################################
    @db.execute_batch <<~SQL
      CREATE TABLE IF NOT EXISTS _cache.texts    (guid TEXT PRIMARY KEY, value TEXT) STRICT;
      CREATE TABLE IF NOT EXISTS _cache.payloads (guid TEXT PRIMARY KEY, value TEXT) STRICT;
      CREATE TABLE IF NOT EXISTS _cache.links    (guid TEXT PRIMARY KEY, value TEXT) STRICT;
    SQL

    @cache = { texts: {}, payload_data: {}, payloads: {}, links: {} }

    cache_text = ->(guid, attr) { @cache[:texts][guid] ||= AttributedStringExtractor.extract(attr) }
    cache_payload = ->(guid, data) do
      @cache[:payload_data][guid] = KeyedArchive.unarchive(data) unless @cache[:payload_data].key? guid
      @cache[:payloads][guid] ||= @cache[:payload_data][guid]&.to_json
    end

    # The `computed` CTE in `message_view` calls these functions which generate the data on demand
    # and populate a cache for a next run. The CTE joins against that cache, and calls these functions
    # for rows where the join is empty.
    # the at_exit block below stores the cache from this run after the program has done its thing.

    @db.ƒ(:cache_text)         { |guid, attr| cache_text.(guid, attr) }
    @db.ƒ(:cache_payload_json) { |guid, data| cache_payload.(guid, data) }

    end_mark = '\uFFFC\p{Space}'  # \uFFFC is the attributed string object marker
    noallow = Regexp.escape('\|^"<>{}[]') + end_mark
    rx_url = %r(\bhttps?://[^#{noallow}]{4,}?(?=["':;,\.\)]{0,3}(?:[#{end_mark}]|$)))i

    @db.ƒ(:cache_link_metadata) do |guid, data, text, attr|
      next @cache[:links][guid] if @cache[:links][guid]
      text = cache_text.(guid, attr)
      cache_payload.(guid, data) # force @cache[:payload_data] to be set
      payload = @cache[:payload_data][guid]

      rich_link = payload&.dig "richLinkMetadata"
      found_url = text[rx_url] if text          # manual extraction, in case no rich link data
      rich_url  = rich_link&.dig "URL"          # canonical or resolved
      orig_url  = rich_link&.dig "originalURL"  # extracted by imessage from text, adds protocol etc
      title     = rich_link&.dig "title"
      summary   = rich_link&.dig "summary"
      image     = rich_link&.dig "imageMetadata", "URL"
      image_idx = rich_link&.dig "image", "richLinkImageAttachmentSubstituteIndex"
      url = rich_url || orig_url || found_url

      link = { url:, title:, summary:, image:, image_idx:, original_url: orig_url } if url
      @cache[:links][guid] = link.to_json
    end

    at_exit do
      # next # disable saving cache
      next if @cache.values.all?(&:empty?)
      quote = ->v{ v == nil ? "NULL" : "'#{SQLite3::Database.quote v}'" }
      batch_size = 50_000
      @db.transaction do
        @cache.except(:payload_data).each do |table, rows|
          rows.each_slice(batch_size) do |rows|
            values = rows.inject(String.new){|s, (guid, v)| s << "('#{guid}', #{quote[v]})," }.chop!
            @db.execute <<~SQL
              INSERT INTO _cache.#{table} (guid, value) VALUES #{values}
              ON CONFLICT(guid) DO UPDATE SET value = COALESCE(excluded.value, _cache.#{table}.value)
            SQL
          end
        end
      end
    end

    ################################################################################
    ### Main message view ##########################################################
    ################################################################################

    unix_time = "((m.date / 1000000000) + #{APPLE_EPOCH})"
    @db.execute <<~SQL
      CREATE TEMP VIEW message_view AS
      WITH chat_members AS (
        SELECT
          c.ROWID as chat_id,
          (COUNT(DISTINCT hg.handle_id) > 1) as is_group_chat,
          json_group_array(DISTINCT hg.name) as member_names,
          json_group_array(DISTINCT term.value) as members_searchable
        FROM _imsg.chat c
        JOIN _imsg.chat_handle_join chj ON c.ROWID = chj.chat_id
        LEFT JOIN handle_groups hg ON chj.handle_id = hg.handle_id
        CROSS JOIN json_each(hg.searchable) as term  -- flatten each member's searchable array
        GROUP BY c.ROWID
      ),
      computed AS (
        SELECT
          m.ROWID,
          COALESCE(m.text, ct.value, IIF(ct.guid IS NULL AND m.attributedBody IS NOT NULL, cache_text(m.guid, m.attributedBody)))
            as text,
          COALESCE(cp.value, IIF(cp.guid IS NULL AND m.payload_data IS NOT NULL, cache_payload_json(m.guid, m.payload_data)))
            as payload_json,
          COALESCE(cl.value, IIF(cl.guid IS NULL AND (
              m.payload_data IS NOT NULL OR instr(m.text, 'http') OR instr(m.attributedBody, 'http')
            ), cache_link_metadata(m.guid, m.payload_data, m.text, m.attributedBody)))
            as link
        FROM message m
        LEFT JOIN _cache.texts    ct ON m.guid = ct.guid
        LEFT JOIN _cache.payloads cp ON m.guid = cp.guid
        LEFT JOIN _cache.links    cl ON m.guid = cl.guid
      )
      SELECT
        m.ROWID                                                             as message_id,
        m.guid,
        m.associated_message_type,
        m.service,
        m.cache_has_attachments                                             as has_attachments,
        mc.text,
        mc.payload_json,
        c.display_name                                                      as chat_name,
        #{unix_time}                                                        as unix_time,
        strftime('%Y-%m-%d', #{unix_time}, 'unixepoch')                     as utc_date,
        strftime('%Y-%m-%d', #{unix_time}, 'unixepoch', 'localtime')        as local_date,
        datetime(#{unix_time}, 'unixepoch')                                 as utc_time,
        datetime(#{unix_time}, 'unixepoch', 'localtime')                    as local_time,
        m.is_from_me                                                        as is_from_me,
        m.payload_data                                                      as payload_data,
        mc.link,
        cm.is_group_chat,

        -- 1. Direct message **from me** → show recipient
        -- 2. Group chat or message **from me** → show all members
        -- 3. Direct message **to me** → null recipients (it me!)
        -- i prefer using these funny conditions as closer to the source than is_group_chat, is_from_me
        CASE
        WHEN hg_recip.name IS NOT NULL --  is not group chat (is DM)
        THEN json_array(hg_recip.name) -- fake an array with single recipient
        -- sender null == is from me, as hg_sender joins on is_from_me=0 → recipients = members
        -- sender != members means more members → group chat (all chat members are recipients (incl sender))
        WHEN hg_sender.searchable IS NULL OR hg_sender.searchable != cm.members_searchable
        THEN cm.member_names
         -- recipient is null and is not from me and sender == members = 'tis I the recipient, so null
        ELSE NULL
        END as recipient_names,                                          -- as recipient_names,  (repeated here for visibility)

        CASE -- same logic
        WHEN hg_recip.searchable IS NOT NULL
        THEN hg_recip.searchable
        WHEN hg_sender.searchable IS NULL OR hg_sender.searchable != cm.members_searchable
        THEN cm.members_searchable
        ELSE NULL
        END as recipients_searchable,                                   --  as recipients_searchable,

        hg_sender.name                                                      as sender_name,
        hg_recip.name                                                       as recipient_name,
        COALESCE(cm.member_names, json_array())                             as member_names,         -- all chat members
        hg_sender.searchable                                                as sender_searchable,    -- for optional filtering
        hg_recip.searchable                                                 as recipient_searchable, -- for optional filtering
        cm.members_searchable                                               as members_searchable    -- for optional filtering

      FROM _imsg.message m
      JOIN computed mc                      ON m.ROWID = mc.ROWID
      LEFT JOIN _imsg.chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN _imsg.chat c                ON cmj.chat_id = c.ROWID
      LEFT JOIN handle_groups hg_sender     ON m.handle_id = hg_sender.handle_id AND m.is_from_me = 0
      LEFT JOIN handle_groups hg_recip      ON m.handle_id = hg_recip.handle_id  AND m.is_from_me = 1
      LEFT JOIN chat_members cm             ON c.ROWID = cm.chat_id
      WHERE
      ((associated_message_type IS NULL OR associated_message_type < 1000)                               -- Exclude associated reaction messages 1000: stickers, 20xx: reactions; 30xx: remove reactions
        AND (balloon_bundle_id IS NULL OR balloon_bundle_id = 'com.apple.messages.URLBalloonProvider')   -- Exclude all payload msgs that are not links. Digital touch lol, Find My, etc
      )
    SQL

    return @db
  end
end
