# frozen_string_literal: true

# Query result formatter that prints SQL results in Very Nice tables

require "io/console"

module Print
  @term_width = IO.console.winsize[1]
  @term_width -= 3 if ENV["TERM_PROGRAM"] == "zed" # safe zone for https://github.com/zed-industries/zed/issues/43629

  def self.c256(c, s) = "\e[38;5;#{c}m#{s}\e[39m"
  def self.mark(s) = "\e[38;5;178m#{s}\e[39m"
  def self.sep(s) = "\e[30m#{s}\e[39m"
  def self.clr = "\e[0m"

  def self.query(q, *args, title: nil, db: Messages.db)
    table db.execute2(q, *args), title:
  end

  def self.table(table, title: nil)
    bg1 = "\e[48;5;4m"
    bga = ["\e[48;5;235m", "\e[48;5;238m"]
    bg = ->{ bg1 ? (bg1.tap{bg1=nil}) : bga.rotate!.first }


    # puts "\n#{'=' * 80}"
    hrow, *rows = table
    # max lengths for each col, but capping the header rows at 5 so big headers with short content don't take up space
    lens = [hrow.map{it[0,5]}].concat(rows).transpose.map{|col|col.map{it.to_s.size}.max||0}
    # is each column number? used for aligning them right
    nums = rows.transpose.map{|col| col.compact.all?{ Numeric===it }}
    hex  = rows.transpose.map{|col| col.compact.all?{ String===it && it !~ /\H/ }}
    hex.zip(0..).each{|h,i| lens[i] = 20 if h } #  hex cols start short

    # available term width for all cols excluding separators
    colsw = @term_width - hrow.size + 1
    # max width per col; start with an even col width then redistribute next
    maxcw = colsw / hrow.size

    # begin redistributing
    bigs = lens
    taken = 0
    while true
      smalls, bigs = bigs.partition{ it <= maxcw } # partition cols under/at max col width
      break if bigs.empty? || smalls.empty?        # can't redistribute if all on either side
      taken += smalls.sum                          # accumulate used up width
      maxcw = (colsw - taken) / bigs.size          # max for remaining bigs: split even
    end
    lens.map!{ [it, maxcw].min }

    # expand col header width while fits; those we capped earlier
    trunc_headers = lens.zip(hrow.map{it.size}, 0..).filter_map{|l,hl,i| [i,hl] if l<hl } # [col index, full header length]
    while lens.sum < colsw && trunc_headers.any? # while still fits and any left to widen
      i, hl = trunc_headers.first                # take first
      next trunc_headers.shift if lens[i] >= hl  # drop and nove on if wide enough
      lens[i] += 1                               # widen
      trunc_headers.rotate!                      # move on to next index
    end

    total_width = lens.sum + hrow.size - 1 # full width table will take

    row_count = "(#{rows.size} row#{?s if rows.size != 1})"
    title = [title, row_count].join(" ")
    puts "\e[48;5;18m" + title.ljust(total_width) + "\e[49m"

    lines = table.map do |row|
      line = row.zip(lens, nums).map do |val, len, num|
        just = ->s{ s.send(num ? :rjust : :ljust, len) }
        next c256(244, just[?∅]) if val.nil?  # special handling for nil
        next c256(112, just["1"]) if val == 1 # color 1 bool true
        next c256(9, just["0"]) if val == 0   # color 0 bool false
        s ||= val.to_s
        s = s.gsub(/\p{Extended_Pictographic}/, "•").gsub(/\R/, "␍").gsub(/\t/, ' ') # remove emojis, nl, tabs (better chance of not mangling columns)
        s = s[0, len-1] + mark(?›) if s.size > len # ellipsis
        just[s]
      end
      bg[] + line*sep(?│) + clr
    end
    puts lines
    puts "\e[48;5;18m" + row_count.ljust(total_width) + "\e[49m"
    puts
  end

end
