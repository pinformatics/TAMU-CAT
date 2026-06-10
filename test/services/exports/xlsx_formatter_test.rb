# frozen_string_literal: true

require "test_helper"

module Exports
  class XlsxFormatterTest < ActiveSupport::TestCase
    test "finish_table freezes header row, adds filter, and sizes columns" do
      package = Axlsx::Package.new
      formatter = XlsxFormatter.new(package.workbook)

      package.workbook.add_worksheet(name: "Readable Export") do |sheet|
        header_row = formatter.add_header_row(sheet, [ "Student", "Long Competency Name" ])
        formatter.add_data_row(sheet, [ "Ada Student", "Public and Population Health Assessment" ])

        formatter.finish_table(sheet, header_row: header_row, column_count: 2)

        assert_equal "A1:B2", sheet.auto_filter.range
        assert_equal 1, sheet.sheet_view.pane.y_split
        assert_equal "A2", sheet.sheet_view.pane.top_left_cell
        assert_equal [ formatter.styles[:header], formatter.styles[:header] ], sheet.rows.first.cells.map(&:style)
        assert_operator sheet.column_info.first.width, :>=, 10
        assert_operator sheet.column_info.second.width, :>, sheet.column_info.first.width
      end
    end

    test "finish_table keeps filters on the last complete row when note rows are shorter" do
      package = Axlsx::Package.new
      formatter = XlsxFormatter.new(package.workbook)

      package.workbook.add_worksheet(name: "Sparse Export") do |sheet|
        header_row = formatter.add_header_row(sheet, [ "Student", "Competency", "Score" ])
        formatter.add_note_row(sheet, [ "No raw data available" ])

        formatter.finish_table(sheet, header_row: header_row, column_count: 3)

        assert_equal "A1:C1", sheet.auto_filter.range
        assert_nothing_raised { package.to_stream.read }
      end
    end
  end
end
