require "io/console"
require "concurrent-ruby"

module Imaginator
  begin
    require_relative "img2png"
    EXTENSION_AVAILABLE = true
  rescue LoadError
    puts "jel;;"
    EXTENSION_AVAILABLE = false
  end

  extend self

  class Image
    Fit = Data.define :w, :h, :c, :r, :pad_h, :pad_w

    def initialize(path) = @path = path
    def dimensions       = @img.dimensions
    def release          = @img.release

    def load
      return unless File.exist? @path
      # @img ||= Img2png::Image.new path: @path # do the the IO in swift, turns out not any faster
      @img ||= Img2png::Image.new data: IO.binread(@path)
      self
    end

    def png_transform w:, h:, pad_h:nil, pad_w:nil
      pad = pad_h || pad_w
      pad_w ||= w if pad
      pad_h ||= h if pad
      @img.convert fit_w:w, fit_h:h, box_w:pad_w, box_h:pad_h
    end

    def fit_cols target_cols
      w_cell, h_cell = Imaginator.cell_size
      w_img,  h_img  = dimensions
      w = target_cols * w_cell # target width in px
      h = w / w_img * h_img    # target height in px
      r = (h / h_cell).ceil    # target rows
      Fit.new w:w.floor, h:h.floor, c:target_cols, r:r, pad_h:(r*h_cell), pad_w:w
    end

    def fit_rows target_rows
      w_cell, h_cell = Imaginator.cell_size
      w_img,  h_img  = dimensions
      h = target_rows * h_cell # target height in px
      w = h / h_img * w_img    # target width in px
      c = (w / w_cell).ceil    # target cols
      Fit.new w:w.floor, h:h.floor, c:c, r:target_rows, pad_w:(c*w_cell), pad_h:h
    end

    def fit cols, rows
      cfit = fit_cols(cols)
      rfit = fit_rows(rows)
      smol = [cfit, rfit].sort_by { [it.w, it.h] }.first
      # ^ they're proportional so whichever smallest is the one containable in both dimensions
      [smol, cfit:, rfit:]
    end

  end


  def term_seq(seq, end_marker)
    t = ->{ Process.clock_gettime Process::CLOCK_MONOTONIC }
    buf = ""
    IO.console.raw do |tty|
      tty << seq
      tty.flush
      timeout = t.() + 0.1
      loop do
        buf << tty.read_nonblock(1)
        break if buf.end_with? end_marker
      rescue IO::WaitReadable
        break if t.() > timeout
        IO.select([tty], nil, nil, 0.01)
      end
    end
    buf
  end

  def term_features = @term_features ||= (term_seq("\e]1337;Capabilities\e\\", ?\a) =~ /Capabilities=([A-Za-z0-9]*)/ and $1.scan(/[A-Z][a-z]?\d*/))
  def iterm_images? = @iterm_images  ||= term_features&.include?(?F)
  def kitty_images? = @kitty_images  ||= term_seq("\e_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\e\\", "\e\\") == "\e_Gi=31;OK\e\\"

  def cell_size # [cell width px, cell height px] (Floats)
    @cell_size ||= case
    when iterm = term_seq("\e]1337;ReportCellSize\e\\", ?\a)[/ReportCellSize=(.*)\e/, 1]
      iterm.split(?;).map{ Float it }.then{ |h, w, s| s ||= 1; [w*s, h*s] } # multiply by retina scale factor
    when csi16t = term_seq("\e[16t", ?t)[/\e\[6;(\d+;\d+)t/, 1] # ghostty
      csi16t.split(?;).map{ Float it }.reverse
    # else calc from TIOCGWINSZ or CSI14/18t, but this is enough for iterm, ghostty
    end
  end

  def term_image_protocol
    return @term_image_protocol unless @term_image_protocol.nil?
    @term_image_protocol = case
    when ENV["TERM_PROGRAM"] == "Apple_Terminal" then false # it echoes back the kitty query and I don't wanna figure out how not to
    when iterm_images? then :iterm # has to go before kitty as iterm responds ok to kitty query but can't render them
    when kitty_images? then :kitty # you're a kitty! yes you are! and you're sitting there! hi, kitty!
    else false
    end
  end

  def image_tooling? = !!(EXTENSION_AVAILABLE && term_image_protocol && cell_size)

  def iterm_print_image data:, r:nil, c:nil, io:$stdout
    head = "\e]1337;"
    io << head << "MultipartFile=inline=1;preserveAspectRatio=1"
    io << ";width="  << c if c
    io << ";height=" << r if r
    io << ?\a
    data = [data].pack("m0")
    (0...data.size).step(200).each{ io << head << "FilePart=" << data[it, 200] << ?\a }
    io << head << "FileEnd" << ?\a
  end

  def kitty_print_image data:, r:nil, c:nil, io:$stdout
    io << "\e_Gf=100,a=T,t=d"
    io << ",c=" << c if c
    io << ",r=" << r if r
    io << ?; << [data].pack("m0") << "\e\\"
  end

  def print_image(...)
    return unless image_tooling?
    case term_image_protocol
    when :iterm then iterm_print_image(...)
    when :kitty then kitty_print_image(...)
    end
  end

end
