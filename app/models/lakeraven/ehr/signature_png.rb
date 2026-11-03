# frozen_string_literal: true

require "zlib"

module Lakeraven
  module EHR
    # The PNG a browser canvas posts. Parsed here, not trusted from its magic
    # bytes: chunks, IHDR, a bounded inflate of IDAT, and unfiltered scanlines.
    # A payload this cannot decode, or that has no visible stroke, is refused.
    #
    # Dimensions are capped to a signature pad before inflate. Scanlines stay
    # binary strings (getbyte); a Ruby array per byte would turn a legal pad
    # into a memory spike, and a larger claimed bitmap is refused outright.
    class SignaturePng
      MAGIC = "\x89PNG\r\n\x1A\n".b
      # The tablet canvas is 600×180. A denser capture may be up to 1800×600.
      # Anything larger is refused before inflate.
      MAX_WIDTH = 1800
      MAX_HEIGHT = 600
      MAX_DECODED_BYTES = 12 * 1024 * 1024
      MIN_VISIBLE_PIXELS = 20
      VISIBLE_ALPHA = 128
      # Rec. 601 luma has to sit at least this far below white (255). A
      # near-white stroke on a white page is not ink.
      LUMINANCE_FROM_WHITE = 64
      SAMPLES = { 0 => 1, 2 => 3, 4 => 2, 6 => 4 }.freeze
      KNOWN_CRITICAL = %w[IHDR PLTE IDAT IEND].freeze

      attr_reader :bytes

      def self.acceptable?(bytes)
        new(bytes).acceptable?
      end

      def initialize(bytes)
        @bytes = bytes.to_s.b
        @idat = +"".b
      end

      # Memoized: validation reuses the object decode_signature_data_url built.
      def acceptable?
        return @acceptable if defined?(@acceptable)

        @acceptable = parsed? && visible_stroke?
      end

      def same_bytes?(other)
        candidate = other.to_s.b
        @bytes.bytesize == candidate.bytesize && @bytes == candidate
      end

      def inspect
        "#<#{self.class.name} #{@width}x#{@height}>"
      end

      private

      def parsed?
        return false unless @bytes.start_with?(MAGIC)
        return false unless read_chunks
        return false unless supported_header?
        return false if @idat.empty?

        @visible_pixels = count_visible_pixels(inflate_idat)
        !@visible_pixels.nil?
      end

      def visible_stroke?
        @visible_pixels.to_i >= MIN_VISIBLE_PIXELS
      end

      def read_chunks
        pos = MAGIC.bytesize
        first = true
        while pos < @bytes.bytesize
          chunk = next_chunk(pos)
          return false unless chunk
          return false if first && chunk[:type] != "IHDR"
          return false unless consume(chunk)

          first = false
          pos = chunk[:next]
          return @ended if @ended && pos == @bytes.bytesize
          return false if @ended
        end
        false
      end

      def next_chunk(pos)
        return nil if pos + 8 > @bytes.bytesize

        length = @bytes.byteslice(pos, 4).unpack1("N")
        return nil if length > @bytes.bytesize

        type = @bytes.byteslice(pos + 4, 4)
        return nil unless type.match?(/\A[A-Za-z]{4}\z/)

        data_end = pos + 8 + length
        return nil if data_end + 4 > @bytes.bytesize

        data = @bytes.byteslice(pos + 8, length)
        crc = @bytes.byteslice(data_end, 4).unpack1("N")
        return nil unless crc == Zlib.crc32(type + data)

        { type: type, data: data, next: data_end + 4 }
      end

      def consume(chunk)
        case chunk[:type]
        when "IHDR" then read_ihdr_once(chunk[:data])
        when "IDAT" then @idat << chunk[:data]
        when "IEND" then @ended = true
        when "tRNS" then false
        else !critical_unknown?(chunk[:type])
        end
      end

      def read_ihdr_once(data)
        return false if @width

        read_ihdr(data)
      end

      def critical_unknown?(type)
        type[0] == type[0].upcase && !KNOWN_CRITICAL.include?(type)
      end

      def read_ihdr(data)
        return false unless data.bytesize == 13

        width, height, bit_depth, color_type, compression, filter, interlace = data.unpack("NNC5")
        @width = width
        @height = height
        @bit_depth = bit_depth
        @color_type = color_type
        compression.zero? && filter.zero? && interlace.zero?
      end

      def supported_header?
        samples = SAMPLES[@color_type]
        return false unless samples && @bit_depth == 8
        return false unless dimensions_allowed?

        @samples = samples
        @row_bytes = @width * samples
        @expected = @height * (@row_bytes + 1)
        @expected <= MAX_DECODED_BYTES
      end

      def dimensions_allowed?
        return false unless @width.positive? && @height.positive?

        @width <= MAX_WIDTH && @height <= MAX_HEIGHT
      end

      def inflate_idat
        return nil if @expected <= 0

        inflater = Zlib::Inflate.new
        output = bounded_inflate(inflater)
        output if output&.bytesize == @expected
      rescue Zlib::Error
        nil
      ensure
        inflater&.close
      end

      def bounded_inflate(inflater)
        output = +"".b
        offset = 0
        while offset < @idat.bytesize
          piece = @idat.byteslice(offset, 4096)
          offset += piece.bytesize
          output << inflater.inflate(piece)
          return nil if output.bytesize > @expected
        end
        output << inflater.finish
        return nil if output.bytesize > @expected

        output
      end

      # One row at a time. Only the previous scanline is kept, for the Up filters.
      def count_visible_pixels(raw)
        return nil unless raw

        prior = nil
        offset = 0
        total = 0
        @height.times do
          row, offset = decode_row(raw, offset, prior)
          return nil unless row

          total += visible_in(row)
          prior = row
        end
        total
      end

      def decode_row(raw, offset, prior)
        return [ nil, offset ] if offset + 1 + @row_bytes > raw.bytesize

        filter = raw.getbyte(offset)
        filtered = raw.byteslice(offset + 1, @row_bytes)
        [ apply_filter(filter, filtered, prior), offset + 1 + @row_bytes ]
      end

      def apply_filter(filter, row, prior)
        case filter
        when 0 then row
        when 1 then filter_sub(row)
        when 2 then filter_up(row, prior)
        when 3 then filter_average(row, prior)
        when 4 then filter_paeth(row, prior)
        end
      end

      def filter_sub(row)
        out = row.dup
        index = @samples
        while index < out.bytesize
          out.setbyte(index, (out.getbyte(index) + out.getbyte(index - @samples)) & 0xff)
          index += 1
        end
        out
      end

      def filter_up(row, prior)
        return row.dup unless prior

        add_prior(row) { |index| prior.getbyte(index) }
      end

      def filter_average(row, prior)
        out = row.dup
        index = 0
        while index < out.bytesize
          left = index >= @samples ? out.getbyte(index - @samples) : 0
          up = prior ? prior.getbyte(index) : 0
          out.setbyte(index, (out.getbyte(index) + ((left + up) / 2)) & 0xff)
          index += 1
        end
        out
      end

      def filter_paeth(row, prior)
        out = row.dup
        index = 0
        while index < out.bytesize
          left = index >= @samples ? out.getbyte(index - @samples) : 0
          up = prior ? prior.getbyte(index) : 0
          up_left = prior && index >= @samples ? prior.getbyte(index - @samples) : 0
          out.setbyte(index, (out.getbyte(index) + paeth(left, up, up_left)) & 0xff)
          index += 1
        end
        out
      end

      def add_prior(row)
        out = row.dup
        index = 0
        while index < out.bytesize
          out.setbyte(index, (out.getbyte(index) + yield(index)) & 0xff)
          index += 1
        end
        out
      end

      def paeth(left_byte, up_byte, up_left)
        estimate = left_byte + up_byte - up_left
        pa = (estimate - left_byte).abs
        pb = (estimate - up_byte).abs
        pc = (estimate - up_left).abs
        return left_byte if pa <= pb && pa <= pc
        return up_byte if pb <= pc

        up_left
      end

      # Ink is the same for every colour type: covered (alpha at least 128,
      # or no alpha channel) and darker than white by the luma threshold.
      # Opaque white, and near-white on transparent paper, are not a stroke.
      def visible_in(row)
        count = 0
        index = 0
        while index + @samples <= row.bytesize
          count += 1 if ink_at?(row, index)
          index += @samples
        end
        count
      end

      def ink_at?(row, index)
        return false unless covered?(row, index)

        red, green, blue = channels_at(row, index)
        luminance_from_white(red, green, blue) >= LUMINANCE_FROM_WHITE
      end

      def covered?(row, index)
        return true unless alpha_channel?

        row.getbyte(index + @samples - 1) >= VISIBLE_ALPHA
      end

      def alpha_channel?
        @color_type == 4 || @color_type == 6
      end

      def channels_at(row, index)
        return gray_channels(row.getbyte(index)) if grayscale?

        [ row.getbyte(index), row.getbyte(index + 1), row.getbyte(index + 2) ]
      end

      def grayscale?
        @color_type == 0 || @color_type == 4
      end

      def gray_channels(value)
        [ value, value, value ]
      end

      # Rec. 601 luma, in integers. White is 255.
      def luminance_from_white(red, green, blue)
        luma = ((299 * red) + (587 * green) + (114 * blue)) / 1000
        255 - luma
      end
    end
  end
end
