# frozen_string_literal: true

module Exports
  # Shared workbook presentation helpers for staff-facing Excel exports.
  class XlsxFormatter
    DEFAULT_MIN_WIDTH = 10
    DEFAULT_MAX_WIDTH = 42

    attr_reader :styles

    def initialize(workbook)
      @workbook = workbook
      @styles = build_styles
    end

    def add_title_row(sheet, values)
      values = Array(values)
      sheet.add_row values, style: repeated_style(:title, values.size)
      sheet.rows.size
    end

    def add_meta_row(sheet, label, value = nil)
      values = value.nil? ? Array(label) : [ label, value ]
      style = [ styles[:meta_label], styles[:meta_value] ].first(values.size)
      sheet.add_row values, style: style
      sheet.rows.size
    end

    def add_header_row(sheet, values, types: nil)
      values = Array(values)
      sheet.add_row values, row_options(:header, values.size, types:)
      sheet.rows.size
    end

    def add_data_row(sheet, values, types: nil)
      values = Array(values)
      sheet.add_row values, row_options(:data, values.size, types:)
      sheet.rows.size
    end

    def add_note_row(sheet, values, types: nil)
      values = Array(values)
      sheet.add_row values, row_options(:note, values.size, types:)
      sheet.rows.size
    end

    def finish_table(sheet, header_row:, column_count:, last_row: nil, widths: nil, freeze: true, auto_filter: true)
      return if column_count.to_i <= 0

      last_row ||= [ sheet.rows.size, header_row ].max
      freeze_below(sheet, header_row) if freeze
      apply_auto_filter(sheet, header_row:, column_count:, last_row:) if auto_filter
      sheet.column_widths(*(widths || inferred_widths(sheet, column_count:)))
    end

    private

    attr_reader :workbook

    def build_styles
      border = { style: :thin, color: "D8DEE9" }
      {
        title: workbook.styles.add_style(
          b: true,
          sz: 14,
          fg_color: "500000",
          alignment: { vertical: :center, wrap_text: true }
        ),
        meta_label: workbook.styles.add_style(
          b: true,
          fg_color: "500000",
          alignment: { vertical: :center, wrap_text: true }
        ),
        meta_value: workbook.styles.add_style(
          fg_color: "374151",
          alignment: { vertical: :center, wrap_text: true }
        ),
        header: workbook.styles.add_style(
          b: true,
          bg_color: "500000",
          fg_color: "FFFFFF",
          alignment: { horizontal: :center, vertical: :center, wrap_text: true },
          border: border
        ),
        data: workbook.styles.add_style(
          alignment: { vertical: :top, wrap_text: true },
          border: border
        ),
        note: workbook.styles.add_style(
          i: true,
          fg_color: "6B7280",
          alignment: { vertical: :top, wrap_text: true },
          border: border
        )
      }
    end

    def repeated_style(style_name, count)
      Array.new(count, styles.fetch(style_name))
    end

    def row_options(style_name, count, types: nil)
      options = { style: repeated_style(style_name, count) }
      options[:types] = types if types.present?
      options
    end

    def freeze_below(sheet, header_row)
      sheet.sheet_view.pane do |pane|
        pane.state = :frozen
        pane.y_split = header_row
        pane.top_left_cell = "A#{header_row + 1}"
        pane.active_pane = :bottom_left
      end
    end

    def apply_auto_filter(sheet, header_row:, column_count:, last_row:)
      filter_last_row = last_full_width_row(sheet, header_row:, column_count:, last_row:)
      return unless filter_last_row

      sheet.auto_filter = "A#{header_row}:#{column_letter(column_count)}#{filter_last_row}"
    end

    def inferred_widths(sheet, column_count:)
      values_by_column = Array.new(column_count) { [] }
      sheet.rows.each do |row|
        row.cells.first(column_count).each_with_index do |cell, index|
          values_by_column[index] << cell.value.to_s
        end
      end

      values_by_column.map do |values|
        longest = values.map { |value| value.length }.max.to_i
        [[ longest + 2, DEFAULT_MIN_WIDTH ].max, DEFAULT_MAX_WIDTH ].min
      end
    end

    def column_letter(index)
      letters = +""
      number = index.to_i

      while number.positive?
        number, remainder = (number - 1).divmod(26)
        letters.prepend((65 + remainder).chr)
      end

      letters
    end

    def last_full_width_row(sheet, header_row:, column_count:, last_row:)
      last_row.to_i.downto(header_row.to_i) do |row_number|
        row = sheet.rows[row_number - 1]
        return row_number if row&.cells&.size.to_i >= column_count.to_i
      end

      nil
    end
  end
end
