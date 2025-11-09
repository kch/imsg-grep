# Simple timer for profiling with lap times and progress bars
module Timer
  # Initialize timer state
  def self.start
    @t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @last_lap = @t0
    @total_time = 0.0
    @laps = []
  end

  # Record lap time with message
  def self.lap(msg)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    lap_time = (now - @last_lap) * 1000
    @total_time += lap_time
    line = "%5.0fms / %5.0fms: #{msg}" % [lap_time, @total_time]
    puts line
    @laps << { msg: msg, time: lap_time, line: line, line_num: @laps.size }
    @last_lap = now
  end

  # Display final timing report with bars and percentages
  def self.finish
    max_lap_time = @laps.map { |lap| lap[:time] }.max
    longest_line = @laps.map { |lap| lap[:line].length }.max
    start_col = longest_line + 3
    @laps.reverse.each do |lap|
      pct = (lap[:time] / @total_time * 100).round(1)
      bar_length = (lap[:time] / max_lap_time * 20).round
      bar = "█" * bar_length + "░" * (20 - bar_length)
      padding = " " * [0, start_col - lap[:line].length].max
      print "\e[#{@laps.size - lap[:line_num]}A\r#{lap[:line]}#{padding}#{bar} #{pct}%\e[#{@laps.size - lap[:line_num]}B\r"
    end
    puts
  end
end
