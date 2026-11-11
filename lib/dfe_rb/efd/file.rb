module DfeRb
  module Efd
    # A file of the EFD: the registers given, in the order its Guia Prático sets, with
    # what the file derives from them: the opening (X001, with or without data) and
    # closing (X990, its line count) of every block, the empty blocks, and Block 9's
    # count of every register (9900), its own count (9990) and the file's (9999).
    #
    # Each file names its blocks, in order (BLOCKS), and its kind of record (RECORD):
    # IcmsIpi::File, Contribuicoes::File.
    #
    # Registers are added at their level: those right below a block's opening here, the
    # others under their parent (Record#add). Within a block, the file orders them by
    # code, those of one code in the order given.
    class File
      LINE_BREAK = "\r\n"

      def initialize
        @records = []
        @lines = nil
      end

      def add(code, values = {})
        raise ArgumentError, "#{code} is written by the file itself" if derived?(code)

        parent = layout.fetch(code).parent
        raise ArgumentError, "#{code} goes under #{parent}" if parent

        @lines = nil
        record_class.new(code, values).tap { |r| @records << r }
      end

      # Every record of the file, derived ones included, in order.
      def lines = @lines ||= build

      # The records of a register code, at any level.
      def records(code) = lines.select { |r| r.code == code }

      # How many lines each register has, by code (what 9900 tells).
      def counts = lines.map(&:code).tally

      # The file as text, each line ended by CR LF. Raises ValidationError with every
      # field of every line that can't be written.
      def to_s
        issues = []
        texts = lines.map do |record|
          record.to_line
        rescue ValidationError => e
          issues.concat(e.issues)
          nil
        end
        raise ValidationError, issues if issues.any?

        texts.join(LINE_BREAK) + LINE_BREAK
      end

      # The bytes of the file, in ISO-8859-1, as the PVA reads it.
      def to_latin1 = to_s.encode(Encoding::ISO_8859_1)

      private

      def record_class = self.class::RECORD

      def layout = record_class.layout

      def derived?(code) = code.match?(/\A.(001|990)\z/) || code.start_with?("9")

      def build
        raise ArgumentError, "the file needs its 0000" unless @records.any? { |r| r.code == "0000" }

        by_block = @records.group_by { |r| r.code[0] }
        lines = self.class::BLOCKS.flat_map { |block| (block == "9") ? [] : block_lines(block, by_block.fetch(block, [])) }
        lines + block_nine(lines)
      end

      def block_lines(block, records)
        ordered = records.each_with_index.sort_by { |record, index| [record.code, index] }.flat_map { |record, _| record.each_line.to_a }
        head, body = ordered.partition { |r| r.code == "0000" }
        opener = record_class.new("#{block}001", second_field("#{block}001") => (block == "0" || body.any?) ? 0 : 1)
        count = head.size + body.size + 2
        head + [opener] + body + [record_class.new("#{block}990", second_field("#{block}990") => count)]
      end

      def block_nine(lines)
        codes = lines.map(&:code).tally
        own = %w[9001 9900 9990 9999]
        registers = codes.keys + own
        nine = [record_class.new("9001", ind_mov: 0)]
        registers.each do |code|
          count = case code
          when "9900" then registers.size
          when "9001", "9990", "9999" then 1
          else codes.fetch(code)
          end
          nine << record_class.new("9900", reg_blc: code, qtd_reg_blc: count)
        end
        nine << record_class.new("9990", qtd_lin_9: nine.size + 2)
        nine << record_class.new("9999", qtd_lin: lines.size + nine.size + 1)
        nine
      end

      # The opening's indicator, the closing's count.
      def second_field(code) = layout.fetch(code).fields[1].key
    end
  end
end
