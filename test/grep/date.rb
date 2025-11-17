#!/usr/bin/env ruby

require "minitest/autorun"
require_relative "../../lib/grep/date"

class DateArgTest < Minitest::Test
  include DateArg

  def test_absolute_dates_basic
    assert_equal Date.new(2024, 1, 1),   parse_date("2024-01-01", false)
    assert_equal Date.new(2024, 1, 1),   parse_date("2024-1-1", false)
    assert_equal Date.new(2024, 12, 31), parse_date("2024-12-31", false)
  end

  def test_absolute_dates_with_time
    now = Time.new(2024, 6, 15, 14, 30, 0, "-05:00")
    assert_equal Time.new(2024, 1, 1, 10, 30, 0, "-05:00"),  parse_date("2024-01-01 10:30", false, now)
    assert_equal Time.new(2024, 1, 1, 10, 30, 0, "-05:00"),  parse_date("2024-01-01T10:30", false, now)
    assert_equal Time.new(2024, 1, 1, 10, 30, 45, "-05:00"), parse_date("2024-01-01 10:30:45", false, now)
    assert_equal Time.new(2024, 1, 1, 10, 30, 45, "-05:00"), parse_date("2024-01-01T10:30:45", false, now)
    assert_equal Time.new(2024, 1, 1, 9, 5, 0, "-05:00"),    parse_date("2024-1-1 9:5", false, now)
    assert_equal Time.new(2024, 1, 1, 10, 30, 0, "Z"),       parse_date("2024-01-01 10:30", true, now)
  end

  def test_absolute_dates_with_timezone
    assert_equal Time.new(2024, 1, 1, 10, 30, 0, "Z"),       parse_date("2024-01-01T10:30Z", false)
    assert_equal Time.new(2024, 1, 1, 10, 30, 45, "+05:30"), parse_date("2024-01-01T10:30:45+05:30", false)
    assert_equal Time.new(2024, 1, 1, 10, 30, 45, "-08:00"), parse_date("2024-01-01T10:30:45-08:00", false)
    assert_equal Time.new(2024, 1, 1, 10, 30, 45, "-0800"),  parse_date("2024-01-01T10:30:45-0800", false)
    assert_equal Time.new(2024, 1, 1, 10, 30, 45, "-08"),    parse_date("2024-01-01T10:30:45-08", false)
    assert_equal Time.new(2024, 12, 31, 23, 59, 59, "Z"),    parse_date("2024-12-31T23:59:59Z", false)
  end

  def test_relative_date_parts
    now = Time.new(2024, 6, 15, 12, 0, 0, "+00:00")
    base = now.to_date
    assert_equal base - 1,  parse_date("1d", false, now)
    assert_equal base - 7,  parse_date("7d", false, now)
    assert_equal base - 7,  parse_date("1w", false, now)
    assert_equal base - 14, parse_date("2w", false, now)
    assert_equal base << 1, parse_date("1m", false, now)
    assert_equal base << 6, parse_date("6m", false, now)
    assert_equal base << 12, parse_date("1y", false, now)
    assert_equal base << 24, parse_date("2y", false, now)
  end

  def test_relative_date_combinations
    now = Time.new(2024, 6, 15, 12, 0, 0, "+00:00")
    base = now.to_date
    assert_equal base << 18,           parse_date("1y6m", false, now)
    assert_equal (base << 18) - 14,    parse_date("1y6m2w", false, now)
    assert_equal (base << 18) - 17,    parse_date("1y6m2w3d", false, now)
    assert_equal base - 19,            parse_date("2w5d", false, now)
    assert_equal (base << 6) - 7,      parse_date("6m1w", false, now)
    assert_equal (base << 14) - 25,    parse_date("1y2m3w4d", false, now)
  end

  def test_relative_time_parts
    now = Time.new(2024, 6, 15, 12, 0, 0, "+00:00")
    assert_equal Time.new(2024, 6, 15, 11, 0, 0, "+00:00"),     parse_date("1h", false, now)
    assert_equal Time.new(2024, 6, 15, 11, 30, 0, "+00:00"),    parse_date("30M", false, now)
    assert_equal Time.new(2024, 6, 15, 11, 59, 15, "+00:00"),   parse_date("45s", false, now)
    assert_equal Time.new(2024, 6, 15, 9, 30, 0, "+00:00"),     parse_date("2h30M", false, now)
    assert_equal Time.new(2024, 6, 15, 10, 29, 15, "+00:00"),   parse_date("1h30M45s", false, now)
  end

  def test_relative_mixed_date_time
    now = Time.new(2024, 6, 15, 12, 0, 0, "+00:00")
    expected_3d2h = Time.new(2024, 6, 12, 10, 0, 0, "+00:00")
    assert_equal expected_3d2h, parse_date("3d2h", false, now)
    assert_equal Time.new(2024, 6, 13, 23, 30, 0, "+00:00"), parse_date("1d12h30M", false, now)
    assert_equal Time.new(2024, 6, 10, 8, 44, 30, "+00:00"), parse_date("5d3h15M30s", false, now)
    assert_equal Time.new(2024, 6, 13, 11, 59, 0, "+00:00"), parse_date("1min2d", false, now)
    assert_equal Time.new(2024, 6, 5, 7, 0, 0, "+00:00"),    parse_date("10d5h", false, now)
    assert_equal Time.new(2024, 5, 23, 8, 0, 0, "+00:00"),   parse_date("3w2d4h", false, now)
  end

  def test_relative_with_minus_prefix
    now = Time.new(2024, 6, 15, 12, 0, 0, "+00:00")
    base = now.to_date
    assert_equal base - 1,  parse_date("-1d", false, now)
    assert_equal base - 7,  parse_date("-1w", false, now)
    assert_equal base << 1, parse_date("-1m", false, now)
    assert_equal base << 12, parse_date("-1y", false, now)
    assert_equal Time,      parse_date("-3d2h", false, now).class
  end

  def test_edge_cases_and_variations
    now = Time.new(2024, 6, 15, 12, 0, 0, "+00:00")
    assert_equal Date, parse_date("0d", false, now).class
    assert_equal Date, parse_date("999d", false, now).class
    assert_equal Date.new(2024, 5, 15),                         parse_date("1m", false, now)
    assert_equal Time.new(2024, 6, 15, 11, 1, 0, "+00:00"),     parse_date("59min", false, now)
    assert_equal Time.new(2024, 6, 14, 12, 0, 1, "+00:00"),     parse_date("23h59min59s", false, now)
  end

  def test_invalid_dates
    assert_raises(DateArg::Error) { parse_date("invalid", false) }
    assert_raises(DateArg::Error) { parse_date("", false) }
    assert_raises(DateArg::Error) { parse_date("2024", false) }
    assert_raises(DateArg::Error) { parse_date("2024-13-01", false) }
    assert_raises(DateArg::Error) { parse_date("2024-13-33", false) }
    assert_raises(DateArg::Error) { parse_date("2024-13-31:33:33", false) }
    assert_raises(DateArg::Error) { parse_date("abc123", false) }
    assert_raises(DateArg::Error) { parse_date("1x", false) }
    assert_raises(DateArg::Error) { parse_date("1z2d", false) }
  end

  def test_case_sensitivity
    now = Time.new(2024, 6, 15, 12, 0, 0, "+00:00")
    assert_equal Time.new(2024, 6, 15, 11, 0, 0, "+00:00"),     parse_date("1h", false, now)
    assert_equal Time.new(2024, 6, 15, 11, 59, 15, "+00:00"),   parse_date("45s", false, now)
    assert_equal Time.new(2024, 6, 15, 11, 30, 0, "+00:00"),    parse_date("30M", false, now)
    assert_equal Date.new(2021, 12, 15),                        parse_date("30m", false, now)
    assert_equal "UTC",                                         parse_date("2024-01-01t10:30z", false).zone
    assert_equal "UTC",                                         parse_date("2024-01-01T10:30Z", false).zone
  end

  def test_utc_flag
    now = Time.new(2024, 6, 15, 12, 0, 0, "+00:00")
    assert_equal Time.new(2024, 1, 1, 10, 30, 0, "Z"),          parse_date("2024-01-01 10:30", true, now)
    assert_equal Time.new(2024, 6, 15, 11, 0, 0, "+00:00"),     parse_date("1h", true, now)
  end
end
