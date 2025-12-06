require "ffi"

module Img2png
  extend FFI::Library
  ffi_lib "#{__dir__}/img2png.dylib"

  attach_function :img2png_load_path, [:string, :pointer, :pointer], :pointer, blocking: true
  attach_function :img2png_load,      [:pointer, :int, :pointer, :pointer], :pointer, blocking: true
  attach_function :img2png_convert,   [:pointer, :int, :int, :int, :int, :pointer, :pointer], :bool, blocking: true
  attach_function :img2png_release,   [:pointer], :void
  attach_function :img2png_free,      [:pointer], :void

  class Image
    def initialize(data)
      out_w = FFI::MemoryPointer.new(:int)
      out_h = FFI::MemoryPointer.new(:int)
      @handle = Img2png.img2png_load(data, data.bytesize, out_w, out_h)
      raise "Failed to load image" if @handle.null?

      @width  = out_w.read_int
      @height = out_h.read_int
    end

    def dimensions = [@width, @height]

    def convert(fit_w: nil, fit_h: nil, box_w: nil, box_h: nil)
      out_data = FFI::MemoryPointer.new(:pointer)
      out_len  = FFI::MemoryPointer.new(:int)

      success = Img2png.img2png_convert(
        @handle,
        fit_w || 0, fit_h || 0,
        box_w || 0, box_h || 0,
        out_data, out_len
      )

      return nil unless success

      ptr = out_data.read_pointer
      len = out_len.read_int
      result = ptr.read_bytes(len)
      Img2png.img2png_free(ptr)
      result
    end

    def release
      Img2png.img2png_release(@handle) unless @handle.null?
      @handle = FFI::Pointer::NULL
    end

    def self.finalize(handle)
      proc { Img2png.img2png_release(handle) unless handle.null? }
    end
  end
end

# # Usage examples
# input = File.binread("x.heic")

# # Load once, use multiple times
# img = Img2png::Image.new(input)

# # Get dimensions
# p img.dimensions  # => [4032, 3024]

# # Convert without scaling
# png = img.convert
# File.binwrite("output.png", png)

# # Fit to 800x600
# png = img.convert(fit_w: 800, fit_h: 600)
# File.binwrite("fitted.png", png)

# # Fit to 800x600 and box in 1024x768
# png = img.convert(fit_w: 800, fit_h: 600, box_w: 1024, box_h: 768)
# File.binwrite("boxed.png", png)

# # Manual cleanup (or let GC handle it)
# img.release
