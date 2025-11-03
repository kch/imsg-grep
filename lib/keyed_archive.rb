#!/usr/bin/env ruby

require "plist"
require "open3"
require "json"
require "base64"

class NSKeyedArchive
  attr_reader :data, :objects

  def self.unarchive(...) = new(...).unarchive

  def initialize(data)
    data = xml_from_binary_plist data if data.start_with?("bplist")
    raise "no xml" unless data.start_with?("<?xml", "<plist")
    @data    = Plist.parse_xml(data)
    @objects = @data["$objects"]
  end

  def unarchive
    top = @data["$top"]
    root_obj = top["root"] or raise "no root"
    full = parse_object(root_obj)
    [full, strip_metadata(full)]
  end

  private

  class BinaryString < String
    def initialize(s) = super(s).force_encoding("BINARY")
    def to_json(...) = Base64.strict_encode64(self).to_json(...)
  end

  def parse_object(obj)
    return nil if obj == "$null"
    return BinaryString.new obj.read if obj.is_a?(StringIO)
    return obj if !obj.is_a?(Hash)
    return parse_object(@objects[obj["CF$UID"]]) if obj["CF$UID"]
    return obj unless obj["$class"]

    case obj["$class"]["$classname"] || @objects[obj["$class"]["CF$UID"]]["$classname"]
    when "NSArray", "NSMutableArray" then (obj["NS.objects"] || []).map { parse_object it }
    when "NSSet", "NSMutableSet"     then (obj["NS.objects"] || []).map { parse_object it }.to_set
    when "NSDictionary", "NSMutableDictionary"
      return {} unless obj["NS.keys"] && obj["NS.objects"]
      keys   = obj["NS.keys"   ].map { parse_object it }
      values = obj["NS.objects"].map { parse_object it }
      keys.zip(values).to_h
    when "NSURL"
      obj.transform_values! { parse_object it }
      return obj["NS.relative"] if obj.key?("NS.relative") && obj["NS.base"].nil?
      obj
    else
      obj.transform_values { parse_object it }
    end
  end

  def strip_metadata(obj)
    case obj
    when Array then obj.map { strip_metadata it }
    when Set   then obj.map { strip_metadata it }.to_set
    when Hash  then obj.except("$class", "$classes").transform_values { strip_metadata it }
    else obj
    end
  end

  def xml_from_binary_plist(data)
    stdout, stderr, status = Open3.capture3("plutil -convert xml1 - -o -",  stdin_data: data, binmode: true)
    return stdout if status.success?
    raise "plutil failed: #{stderr}"
  end

end


if __FILE__ == $0
  input = $stdin.read
  _, stripped = NSKeyedArchive.unarchive(input)
  puts JSON.pretty_generate(stripped)
end
