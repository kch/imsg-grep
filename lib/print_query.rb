def print_query(db, sql)
  puts "\n#{'=' * 80}"
  cols = []

  db.execute2(sql) do |row|
    if cols.empty?
      cols = row
      next
    end
    width = cols.map(&:length).max

    row.each_with_index do |val, i|
      val = val.nil? ? "NULL" : val.to_s
      puts "#{cols[i].ljust(width, ' ')} : #{val.gsub("\n", "\n   " + ' ' * width)}"
    end
    puts "-" * 80
  end
end