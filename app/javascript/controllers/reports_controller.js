import { Controller } from "@hotwired/stimulus"
import { createRoot } from "react-dom/client"
import React from "react"
import ReportsApp from "reports/app"

export default class extends Controller {
  static values = {
    pdfUrl: String,
    excelUrl: String,
    initialFilters: Object
  }

  connect() {
    const exportUrls = {
      pdf: this.hasPdfUrlValue ? this.pdfUrlValue : null,
      excel: this.hasExcelUrlValue ? this.excelUrlValue : null
    }
    const initialFilters = this.hasInitialFiltersValue ? this.initialFiltersValue : {}
    this.reactRoot = createRoot(this.element)
    this.reactRoot.render(React.createElement(ReportsApp, { exportUrls, initialFilters }))
  }

  disconnect() {
    if (this.reactRoot) {
      this.reactRoot.unmount()
      this.reactRoot = null
    }
  }
}
