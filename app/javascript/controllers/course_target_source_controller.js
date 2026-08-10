import { Controller } from "@hotwired/stimulus"

// Toggles the "new course" text fields on the Course Targets admin form,
// shown only when the course dropdown is set to "Add a new course".
export default class extends Controller {
  static targets = ["select", "newFields"]

  connect() {
    this.sync()
  }

  sync() {
    if (!this.hasSelectTarget || !this.hasNewFieldsTarget) return

    const addingNew = this.selectTarget.value === ""
    this.newFieldsTarget.hidden = !addingNew
  }
}
