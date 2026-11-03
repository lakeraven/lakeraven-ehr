# frozen_string_literal: true

require "zlib"

module Lakeraven
  module EHR
    # The PNG a browser canvas posts. Parsed here, not trusted from its magic
    # bytes: chunks, IHDR, a bounded inflate of IDAT, and unfiltered scanlines.
    # A payload this cannot decode, or that has no ink, is refused.
    class SignaturePng
      MAGIC = "\x89PNG\r\n\x1A\n".b
      # A signature pad is a few hundred pixels on a side. Anything larger is
      # refused before inflate so a claimed bitmap cannot expand into a bomb.
      MAX_PIXELS = 2_000_000
      MAX_DECODED_BYTES = 12 * 1024 * 1024
      SAMPLES = { 0 => 1, 2 => 3, 4 => 2, 6 => 4 }.freeze
      KNOWN_CRITICAL = %w[IHDR PLTE IDAT IEND].freeze

      def self.acceptable?(bytes)
        new(bytes).acceptable?
      end

      def initialize(bytes)
        @bytes = bytes.to_s.b
        @idat = +"".b
      end

      def acceptable?
        return false unless parsed?

        inked?
      end

      private

      def parsed?
        return false unless @bytes.start_with?(MAGIC)
        return false unless read_chunks
        return false unless supported_header?
        return false if @idat.empty?

        @rows = reconstruct(inflate_idat)
        !@rows.nil?
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
        return false unless dimensions_allowed?(samples)

        @samples = samples
        @row_bytes = @width * samples
        @expected = @height * (@row_bytes + 1)
        @expected <= MAX_DECODED_BYTES
      end

      def dimensions_allowed?(samples)
        return false unless @width.positive? && @height.positive?
        return false if @width > MAX_PIXELS || @height > MAX_PIXELS
        return false if @width > (MAX_PIXELS / @height)

        pixel_bytes = @width * @height * samples
        pixel_bytes <= MAX_DECODED_BYTES
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
        @idat.bytesize.times do |index|
          output << inflater.inflate(@idat.byteslice(index, 1))
          return nil if output.bytesize > @expected
        end
        output << inflater.finish
        output
      end

      def reconstruct(raw)
        return nil unless raw

        rows = []
        offset = 0
        @height.times do
          row, offset = reconstruct_scanline(raw, offset, rows.last)
          return nil unless row

          rows << row
        end
        rows
      end

      def reconstruct_scanline(raw, offset, prior)
        return [ nil, offset ] if offset + 1 + @row_bytes > raw.bytesize

        filter = raw.getbyte(offset)
        filtered = raw.byteslice(offset + 1, @row_bytes).bytes
        [ unfilter(filter, filtered, prior), offset + 1 + @row_bytes ]
      end

      def unfilter(filter, row, prior)
        case filter
        when 0 then row
        when 1 then unfilter_sub(row)
        when 2 then unfilter_up(row, prior)
        when 3 then unfilter_average(row, prior)
        when 4 then unfilter_paeth(row, prior)
        end
      end

      def unfilter_sub(row)
        built = []
        row.each { |byte| built << ((byte + left(built, built.length)) & 0xff) }
        built
      end

      def unfilter_up(row, prior)
        row.each_with_index.map { |byte, index| (byte + above(prior, index)) & 0xff }
      end

      def unfilter_average(row, prior)
        built = []
        row.each_with_index do |byte, index|
          average = (left(built, index) + above(prior, index)) / 2
          built << ((byte + average) & 0xff)
        end
        built
      end

      def unfilter_paeth(row, prior)
        built = []
        row.each_with_index do |byte, index|
          built << ((byte + paeth(left(built, index), above(prior, index), above_left(prior, index))) & 0xff)
        end
        built
      end

      def left(row, index)
        index >= @samples ? row[index - @samples] : 0
      end

      def above(prior, index)
        prior ? prior[index] : 0
      end

      def above_left(prior, index)
        return 0 unless prior && index >= @samples

        prior[index - @samples]
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

      def inked?
        pixels = pixels_from(@rows)
        return false if pixels.empty?
        return inked_alpha?(pixels) if alpha_channel?

        inked_opaque?(pixels, drop_alpha: false)
      end

      def alpha_channel?
        @color_type == 4 || @color_type == 6
      end

      def pixels_from(rows)
        rows.flat_map { |row| row.each_slice(@samples).to_a }
      end

      # Transparent paper with a stroke has both zero and non-zero alpha.
      # A fully opaque image needs a pixel that is not the background. A
      # one-pixel mark counts unless it is blank white.
      def inked_alpha?(pixels)
        return false if pixels.none? { |pixel| pixel.last.positive? }
        return true if pixels.any? { |pixel| pixel.last < 255 }

        inked_opaque?(pixels, drop_alpha: true)
      end

      def inked_opaque?(pixels, drop_alpha:)
        comparable = drop_alpha ? pixels.map { |pixel| pixel[0..-2] } : pixels
        return !white?(comparable.first) if comparable.one?

        background = comparable.first
        comparable.any? { |pixel| pixel != background }
      end

      def white?(samples)
        samples.all? { |sample| sample == 255 }
      end
    end
  end
end
