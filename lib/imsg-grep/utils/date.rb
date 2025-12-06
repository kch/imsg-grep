# frozen_string_literal: true
require "time"

# DateArg - Flexible date/time parser supporting multiple input formats
#
# Supported formats:
#
# Absolute dates:
#   2024-01-01              => Date object
#   2024-1-1                => Date object (relaxed format)
#   2024-12-31              => Date object
#
# Absolute dates with time (inherits timezone from 'now' parameter):
#   2024-01-01 10:30        => Time object
#   2024-01-01T10:30        => Time object
#   2024-01-01 10:30:45     => Time object with seconds
#   2024-1-1 9:5            => Time object (relaxed format)
#
# Absolute dates with explicit timezone:
#   2024-01-01T10:30Z       => Time object in UTC
#   2024-01-01T10:30+05:30  => Time object with timezone
#   2024-01-01T10:30-08:00  => Time object with timezone
#   2024-01-01T10:30-0800   => Time object (compact timezone)
#   2024-01-01T10:30-08     => Time object (short timezone)
#
# Time only (uses current date from 'now' parameter):
#   1:34                    => Time object (24-hour format)
#   23:59                   => Time object (24-hour format)
#   10a, 10am               => Time object (10 AM)
#   10p, 10pm               => Time object (10 PM)
#   12:34a                  => Time object (12:34 AM, converts 12 to 0)
#   12:45p                  => Time object (12:45 PM, keeps 12)
#   0:34a                   => Time object (12:34 AM)
#   0p                      => Time object (12:00 PM, converts 0 to 12)
#
# Relative dates (going back in time from 'now'):
#   1d                      => Date 1 day ago
#   7d                      => Date 7 days ago
#   1w                      => Date 1 week (7 days) ago
#   2w                      => Date 2 weeks (14 days) ago
#   1m                      => Date 1 month ago
#   6m                      => Date 6 months ago
#   1y                      => Date 1 year (12 months) ago
#   2y                      => Date 2 years (24 months) ago
#
# Relative date combinations:
#   1y6m                    => Date 1 year 6 months ago
#   1y6m2w                  => Date 1 year 6 months 2 weeks ago
#   1y6m2w3d                => Date 1 year 6 months 2 weeks 3 days ago
#   6m1w                    => Date 6 months 1 week ago
#
# Relative time (going back from 'now'):
#   1h                      => Time 1 hour ago
#   30M, 30min              => Time 30 minutes ago
#   45s                     => Time 45 seconds ago
#   2h30M                   => Time 2 hours 30 minutes ago
#   1h30M45s                => Time 1 hour 30 minutes 45 seconds ago
#
# Mixed relative date and time:
#   3d2h                    => Time 3 days 2 hours ago
#   1d12h30M                => Time 1 day 12 hours 30 minutes ago
#   5d3h15M30s              => Time 5 days 3 hours 15 minutes 30 seconds ago
#   1min2d                  => Time 2 days 1 minute ago (order doesn't matter)
#   3w2d4h                  => Time 3 weeks 2 days 4 hours ago
#
# Optional minus prefix (treated same as without):
#   -1d                     => Same as 1d
#   -3d2h                   => Same as 3d2h
#
# Notes:
# - Case insensitive for timezone (Z/z) and am/pm suffixes
# - 'M' = minutes, 'm' = months in relative formats
# - 12-hour time: 12am = midnight, 12pm = noon
# - UTC flag converts 'now' to UTC before processing
# - Invalid formats raise DateArg::Error

module DateArg
  RX_DATE          = /\A(?<year>\d{4})-(?<month>\d{1,2})-(?<day>\d{1,2})(?<time>[ T](?<hour>\d{1,2}):(?<min>\d{1,2})(?::(?<sec>\d{1,2}))?(?<zone>Z|[+-]\d{2}(?::?\d{2})?)?)?\z/i # mix of iso8601 and rfc3339 with some allowances for lazy typists¯\_(ツ)_/¯
  RX_TIME          = /\A(?:(?<h>0?\d|1[0-2])(?::(?<m>[0-5]\d))?(?<ampm>[ap]m?)|(?<h>[01]?\d|2[0-3]):(?<m>[0-5]\d))\z/i
  RX_REL_TIME_PART = /(\d+)([hMs]|min)/
  RX_REL_DATE_PART = /(\d+)([ywd]|m(?!in))/
  RX_REL_DATE      = /\A-?(#{RX_REL_DATE_PART}|#{RX_REL_TIME_PART})+\z/ # 5y7m4d style (before now); allow optional - in case -23d reads more intuitively than 23d (in the past), but treat both the same

  class Error < StandardError; end

  def self.parse(str, utc = false, now = Time.now)
    now = now.utc if utc
    case str
    in RX_DATE if $~[:zone] then Time.new(*$~.values_at(:year, :month, :day, :hour, :min, :sec), $~[:zone].then{|z| z == ?z ? ?Z : z })
    in RX_DATE if $~[:time] then Time.new(*$~.values_at(:year, :month, :day, :hour, :min, :sec), now.strftime("%z"))
    in RX_DATE              then Date.new(*$~.values_at(:year, :month, :day).map(&:to_i))
    in RX_REL_DATE
      date = str.scan(RX_REL_DATE_PART).inject(now.to_date) do |d, (n, u)|
        op = u =~ /[wd]/ ? :- : :<< # - for days, weeks, << for months, years
        n = n.to_i
        n = n * 7  if u == ?w   # week = 7d
        n = n * 12 if u == ?y   # year = 12mo
        d.send(op, n)
      end
      return date unless RX_REL_TIME_PART =~ str
      t = Time.new(date.year, date.month, date.day, now.hour, now.min, now.sec, now.strftime("%z"))
      str.scan(RX_REL_TIME_PART).inject(t){ |t, (n, u)| t - n.to_i * { s:1, m:60, h:60*60 }[u[0].downcase.to_sym] }
    in RX_TIME
      $~ => h:, m:, ampm:
      m  = m.to_i
      h  = h.to_i
      h  =  0 if ampm =~ /a/i && h == 12
      h += 12 if ampm =~ /p/i && h < 12
      Time.new(now.year, now.month, now.day, h, m, 0, now.strftime("%z"))
    else raise ArgumentError
    end
  rescue ArgumentError # from Time/Date.new too
    raise Error
  end

  def parse_date(...) = DateArg.parse(...)
end
