# frozen_string_literal: true
require "time"

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
