import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    surveyNumber: Number,
    surveyTitle: String
  }

  static targets = [
    "row",
    "checkbox",
    "rowIndicator",
    "selectAll",
    "search",
    "counter",
    "trackFilter",
    "yearFilter",
    "dueDateInput",
    "unassignTrackHidden",
    "unassignYearHidden",
    "assignTrackHidden",
    "assignYearHidden",
    "assignDueHidden",
    "extendTrackHidden",
    "extendYearHidden",
    "extendDueHidden",
    "unassignSelection",
    "assignSelection",
    "extendSelection"
  ]

  connect() {
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = false
    })
    this.refreshSelectionState()
  }

  filterRows() {
    const query = (this.hasSearchTarget ? this.searchTarget.value : "").toString().trim().toLowerCase()

    this.rowTargets.forEach((row) => {
      const name = (row.dataset.studentName || "").toLowerCase()
      const email = (row.dataset.studentEmail || "").toLowerCase()
      const visible = query.length === 0 || name.includes(query) || email.includes(query)
      row.classList.toggle("hidden", !visible)
    })

    this.refreshSelectionState()
  }

  toggleAll(event) {
    const checked = event.target.checked

    this.checkboxTargets.forEach((checkbox) => {
      if (this.isCheckboxVisible(checkbox)) {
        checkbox.checked = checked
      }
    })

    this.refreshSelectionState()
  }

  applyFiltersToSelection() {
    const selectedTrack = this.hasTrackFilterTarget ? this.trackFilterTarget.value.toLowerCase() : ""
    const selectedYear = this.hasYearFilterTarget ? this.yearFilterTarget.value : ""

    this.checkboxTargets.forEach((checkbox) => {
      const row = checkbox.closest("tr")
      if (!row) return

      const rowTrack = (row.dataset.studentTrack || "").toLowerCase()
      const rowYear = row.dataset.studentProgramYear || ""

      const trackMatches = selectedTrack.length === 0 || rowTrack === selectedTrack
      const yearMatches = selectedYear.length === 0 || rowYear === selectedYear

      checkbox.checked = trackMatches && yearMatches
    })

    this.refreshSelectionState()
  }

  markChanged() {
    this.refreshSelectionState()
  }

  async prepareAssignGroup(event) {
    this.syncBulkFormFields()

    const selectedIds = this.selectedStudentIds()
    if (selectedIds.length === 0) {
      event.preventDefault()
      this.alert("Select at least one student to assign.", "No students selected")
      return
    }

    const track = (this.hasTrackFilterTarget ? this.trackFilterTarget.value : "").trim() || "selected track"
    const year = (this.hasYearFilterTarget ? this.yearFilterTarget.value : "").trim()
    const scope = year.length > 0 ? `${track}, Class of ${year}` : track

    const surveyNumber = this.hasSurveyNumberValue ? this.surveyNumberValue : ""
    const surveyLabel = surveyNumber ? `Survey #${surveyNumber}` : "This survey"
    const summary = `You are about to assign ${surveyLabel} to ${selectedIds.length} student${selectedIds.length === 1 ? "" : "s"} in ${scope}. Proceed?`

    await this.confirmSubmit(event, summary, "Assign students")
  }

  async prepareExtendDeadline(event) {
    this.syncBulkFormFields()

    const selectedIds = this.selectedStudentIds()
    if (selectedIds.length === 0) {
      event.preventDefault()
      this.alert("Select at least one student to change deadline.", "No students selected")
      return
    }

    const dueDate = this.hasDueDateInputTarget ? this.dueDateInputTarget.value.toString().trim() : ""
    const dueLabel = dueDate.length > 0 ? dueDate : "the survey default deadline"

    const track = (this.hasTrackFilterTarget ? this.trackFilterTarget.value : "").trim() || "selected track"
    const year = (this.hasYearFilterTarget ? this.yearFilterTarget.value : "").trim()
    const scope = year.length > 0 ? `${track}, Class of ${year}` : track

    const summary = `You are about to change student deadlines for ${selectedIds.length} student${selectedIds.length === 1 ? "" : "s"} in ${scope} to ${dueLabel}.\n\nThis updates selected students' assignment deadlines, not the survey deadline. To change the survey deadline for everyone, use Survey Builder.\n\nProceed?`

    await this.confirmSubmit(event, summary, "Change deadlines")
  }

  async prepareUnassign(event) {
    this.syncBulkFormFields()

    const selectedIds = this.selectedStudentIds()
    if (selectedIds.length === 0) {
      event.preventDefault()
      this.alert("Select at least one student to unassign.", "No students selected")
      return
    }

    await this.confirmSubmit(
      event,
      `You are about to unassign this survey for ${selectedIds.length} student${selectedIds.length === 1 ? "" : "s"}. Completed assignments will be skipped. Proceed?`,
      "Unassign students"
    )
  }

  async confirmSubmit(event, message, title) {
    const form = event.target
    if (form && form.dataset.assignmentModalConfirmed === "true") {
      delete form.dataset.assignmentModalConfirmed
      return
    }

    event.preventDefault()
    event.stopImmediatePropagation()

    const confirmed = window.AppModal && typeof window.AppModal.confirm === "function"
      ? await window.AppModal.confirm({ title, message })
      : window.confirm(message)

    if (!confirmed || !form) return

    form.dataset.assignmentModalConfirmed = "true"
    if (typeof form.requestSubmit === "function") {
      form.requestSubmit(event.submitter || undefined)
    } else {
      form.submit()
    }
  }

  alert(message, title = "Notice") {
    if (window.AppModal && typeof window.AppModal.alert === "function") {
      window.AppModal.alert({ title, message })
      return
    }

    window.alert(message)
  }

  clearFiltersAndSelection() {
    if (this.hasSearchTarget) {
      this.searchTarget.value = ""
    }

    if (this.hasTrackFilterTarget) {
      this.trackFilterTarget.value = ""
    }

    if (this.hasYearFilterTarget) {
      this.yearFilterTarget.value = ""
    }

    if (this.hasDueDateInputTarget) {
      this.dueDateInputTarget.value = ""
    }

    this.rowTargets.forEach((row) => {
      row.classList.remove("hidden")
    })

    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = false
    })

    this.refreshSelectionState()
  }

  refreshSelectionState() {
    this.syncSelectAll()
    this.syncSelectionTargets()
    this.updateRowIndicators()
    this.updateCounter()
  }

  updateRowIndicators() {
    this.rowTargets.forEach((row) => {
      const checkbox = row.querySelector("input[data-assignment-students-target='checkbox']")
      const indicator = row.querySelector("[data-assignment-students-target='rowIndicator']")
      if (!checkbox || !indicator) return

      if (checkbox.checked) {
        indicator.textContent = "Selected for changes"
        indicator.classList.add("changed")
        row.classList.add("c-table-row--changed")
      } else {
        indicator.textContent = "No changes"
        indicator.classList.remove("changed")
        row.classList.remove("c-table-row--changed")
      }
    })
  }

  syncSelectAll() {
    if (!this.hasSelectAllTarget) return

    const visibleCheckboxes = this.visibleCheckboxes()
    const selectedCount = visibleCheckboxes.filter((checkbox) => checkbox.checked).length

    if (visibleCheckboxes.length === 0) {
      this.selectAllTarget.checked = false
      this.selectAllTarget.indeterminate = false
      return
    }

    this.selectAllTarget.checked = selectedCount === visibleCheckboxes.length
    this.selectAllTarget.indeterminate = selectedCount > 0 && selectedCount < visibleCheckboxes.length
  }

  syncSelectionTargets() {
    const ids = this.selectedStudentIds()
    this.writeSelectionInputs(this.unassignSelectionTargets, ids)
    this.writeSelectionInputs(this.assignSelectionTargets, ids)
    this.writeSelectionInputs(this.extendSelectionTargets, ids)
    this.syncBulkFormFields()
  }

  syncBulkFormFields() {
    const track = this.hasTrackFilterTarget ? this.trackFilterTarget.value : ""
    const year = this.hasYearFilterTarget ? this.yearFilterTarget.value : ""
    const due = this.hasDueDateInputTarget ? this.dueDateInputTarget.value : ""

    this.unassignTrackHiddenTargets.forEach((target) => {
      target.value = track
    })

    this.unassignYearHiddenTargets.forEach((target) => {
      target.value = year
    })

    this.assignTrackHiddenTargets.forEach((target) => {
      target.value = track
    })

    this.assignYearHiddenTargets.forEach((target) => {
      target.value = year
    })

    this.assignDueHiddenTargets.forEach((target) => {
      target.value = due
    })

    this.extendTrackHiddenTargets.forEach((target) => {
      target.value = track
    })

    this.extendYearHiddenTargets.forEach((target) => {
      target.value = year
    })

    this.extendDueHiddenTargets.forEach((target) => {
      target.value = due
    })
  }

  updateCounter() {
    if (!this.hasCounterTarget) return

    const selected = this.selectedStudentIds().length
    const visible = this.visibleCheckboxes().length
    const total = this.checkboxTargets.length

    if (selected === 0) {
      this.counterTarget.textContent = `No students selected. Showing ${visible} of ${total}.`
      return
    }

    this.counterTarget.textContent = `Selected ${selected} student${selected === 1 ? "" : "s"}. Showing ${visible} of ${total}.`
  }

  writeSelectionInputs(targets, ids) {
    targets.forEach((container) => {
      container.innerHTML = ""
      ids.forEach((studentId) => {
        const input = document.createElement("input")
        input.type = "hidden"
        input.name = "student_ids[]"
        input.value = studentId
        container.appendChild(input)
      })
    })
  }

  selectedStudentIds() {
    return this.checkboxTargets
      .filter((checkbox) => checkbox.checked)
      .map((checkbox) => checkbox.value)
  }

  visibleCheckboxes() {
    return this.checkboxTargets.filter((checkbox) => this.isCheckboxVisible(checkbox))
  }

  isCheckboxVisible(checkbox) {
    const row = checkbox.closest("tr")
    if (!row) return true

    return !row.classList.contains("hidden")
  }
}
