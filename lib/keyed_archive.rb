#!/usr/bin/env ruby

require "plist"
require "open3"
require "json"

class NSKeyedArchive
  attr_reader :data, :objects

  def self.unarchive(...) = new(...).unarchive

  def initialize(data, strip_meta: false)
    data = xml_from_binary_plist data if data.start_with?("bplist")
    raise "no xml" unless data.start_with?("<?xml", "<plist")
    @data       = Plist.parse_xml(data)
    @objects    = @data["$objects"]
    @strip_meta = strip_meta
  end

  def unarchive
    top = @data["$top"]
    return parse_object(top["root"]) if top["root"]

    candidates = top.except "version"
    return parse_object(candidates.values.first) if candidates.size == 1

    raise "Ambiguous root object - multiple candidates: #{candidates.keys}"
  end

  private

  def parse_object(obj)
    return nil if obj == "$null"
    return obj if !obj.is_a?(Hash)
    return parse_object(@objects[obj["CF$UID"]]) if obj["CF$UID"]
    return obj unless obj["$class"]

    case @objects[obj["$class"]["CF$UID"]]["$classname"]
    when "NSArray", "NSMutableArray" then (obj["$objects"] || []).map { |x| parse_object(x) }
    when "NSSet", "NSMutableSet"     then (obj["$objects"] || []).map { |x| parse_object(x) }.to_set
    when "NSDictionary", "NSMutableDictionary"
      return {} unless obj["NS.keys"] && obj["NS.objects"]
      keys   = obj["NS.keys"   ].map { parse_object _1 }
      values = obj["NS.objects"].map { parse_object _1 }
      keys.zip(values).to_h
    else
      result = obj.transform_values { |v| parse_object(v) }
      @strip_meta ? result.except("$class", "$classes") : result
    end
  end

  def xml_from_binary_plist(data)
    stdout, stderr, status = Open3.capture3("plutil -convert xml1 - -o -",  stdin_data: data, binmode: true)
    return stdout if status.success?
    raise "plutil failed: #{stderr}"
  end
end

if __FILE__ == $0
  input  = $stdin.read
  result = NSKeyedArchive.unarchive(input, strip_meta: true)
  puts JSON.pretty_generate(result)
end
