import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// Google-Forms-like sidebar navigation for the admin survey builder.
// - Builds a left sidebar list for Sections and Categories.
// - Click to scroll to the corresponding block.
// - Refreshes automatically when nested fields are added/removed.
export default class extends Controller {
  static targets = [
    "sidebar",
    "content",
    "sectionsNav",
    "categoriesNav",
    "sectionsContainer",
    "categoriesContainer",
    "addSectionButton",
    "addCategoryButton",
    "addQuestionButton",
    "focusModeButton",
    "navSearchInput",
    "referenceToggleButton",
    "referencePanel",
    "referenceBackdrop"
  ]

  connect() {
    this.refresh = this.refresh.bind(this)
    this.handleInput = this.handleInput.bind(this)
    this.handleChange = this.handleChange.bind(this)
    this._refreshQueued = false
    this.focusModeEnabled = true
    this.activeSectionId = null
    this.referenceOpen = false
    this.lastFocusedElementBeforeReference = null
    this.handleDocumentKeydown = this.handleDocumentKeydown.bind(this)

    // Refresh when other controllers change the DOM.
    window.addEventListener("survey:sections-changed", this.refresh)
    window.addEventListener("survey:categories-changed", this.refresh)
    window.addEventListener("survey:questions-changed", this.refresh)

    // Live updates while typing/editing (category names are not broadcast elsewhere).
    this.element.addEventListener("input", this.handleInput)
    this.element.addEventListener("change", this.handleChange)
    document.addEventListener("keydown", this.handleDocumentKeydown)

    this.refresh()
    this.setupObservers()
    this.updateFocusModeUi()
    this.syncReferencePanelUi()

    this.initSortables()
    this.observeForNewQuestionLists()
  }

  disconnect() {
    window.removeEventListener("survey:sections-changed", this.refresh)
    window.removeEventListener("survey:categories-changed", this.refresh)
    window.removeEventListener("survey:questions-changed", this.refresh)

    this.element.removeEventListener("input", this.handleInput)
    this.element.removeEventListener("change", this.handleChange)
    document.removeEventListener("keydown", this.handleDocumentKeydown)

    if (this._sectionObserver) this._sectionObserver.disconnect()
    if (this._categoryObserver) this._categoryObserver.disconnect()

    if (this._domObserver) this._domObserver.disconnect()
    if (this._sectionSortable) this._sectionSortable.destroy()
    if (this._categorySortables) {
      this._categorySortables.forEach((sortable) => sortable.destroy())
    }
    if (this._questionSortables) {
      this._questionSortables.forEach((sortable) => sortable.destroy())
    }
  }

  initSortables() {
    this._questionSortables ||= new Map()
    this._categorySortables ||= new Map()

    const sectionsList = this.sectionsContainerTarget?.querySelector('[data-section-fields-target="container"]')
    if (sectionsList && !this._sectionSortable) {
      this._sectionSortable = new Sortable(sectionsList, {
        animation: 150,
        handle: ".js-drag-handle",
        draggable: "[data-builder-kind='section']",
        onEnd: () => {
          this.renumberSections()
          this.queueRefresh()
        }
      })
    }

    this.initCategorySortables()

    this.initQuestionSortables()
  }

  initCategorySortables() {
    const root = this.categoriesContainerTarget || this.element
    const lists = Array.from(root.querySelectorAll("[data-category-group-list], [data-no-section-group-list]"))
    lists.forEach((list) => {
      if (this._categorySortables.has(list)) return

      const sortable = new Sortable(list, {
        animation: 150,
        handle: ".js-drag-handle",
        draggable: "[data-builder-kind='category']",
        onEnd: () => {
          this.renumberCategories()
          this.queueRefresh()
        }
      })
      this._categorySortables.set(list, sortable)
    })
  }

  initQuestionSortables() {
    const categoryNodes = Array.from(this.categoriesContainerTarget?.querySelectorAll("[data-builder-kind='category']") || [])
    categoryNodes.forEach((categoryNode) => {
      const list = categoryNode.querySelector('[data-question-fields-target="container"]')
      if (!list) return
      if (this._questionSortables.has(list)) return

      const sortable = new Sortable(list, {
        animation: 150,
        handle: ".js-drag-handle",
        draggable: '[data-question-fields-target="item"]',
        onEnd: () => {
          this.renumberQuestionsInCategory(categoryNode)
          this.queueRefresh()
        }
      })
      this._questionSortables.set(list, sortable)
    })
  }

  observeForNewQuestionLists() {
    if (this._domObserver) return
    this._domObserver = new MutationObserver(() => {
      this.initQuestionSortables()
      this.initCategorySortables()
    })

    const root = this.categoriesContainerTarget || this.element
    this._domObserver.observe(root, { childList: true, subtree: true })
  }

  renumberSections() {
    const list = this.sectionsContainerTarget?.querySelector('[data-section-fields-target="container"]')
    if (!list) return
    const items = Array.from(list.querySelectorAll("[data-builder-kind='section']")).filter((n) => !this.isHidden(n))
    items.forEach((node, idx) => {
      const input = node.querySelector('input[name$="[position]"]')
      if (input) input.value = String(idx + 1)
    })
  }

  renumberCategories() {
    const root = this.categoriesContainerTarget || this.element
    const items = Array.from(root.querySelectorAll("[data-builder-kind='category']")).filter((n) => !this.isHidden(n))
    items.forEach((node, idx) => {
      const input = node.querySelector('input[name$="[position]"]')
      if (input) input.value = String(idx + 1)
    })
  }

  renumberQuestionsInCategory(categoryNode) {
    if (!categoryNode) return
    const list = categoryNode.querySelector('[data-question-fields-target="container"]')
    if (!list) return
    const items = Array.from(list.querySelectorAll('[data-question-fields-target="item"]')).filter((n) => !this.isHidden(n))

    // Parent questions: parent_question_id blank.
    let parentIndex = 0
    const parentOrderById = new Map()
    const parentNodes = []
    const reflectionNodesByBaseKey = new Map()
    const unmatchedReflectionNodes = []

    items.forEach((node) => {
      const parentSelect = node.querySelector('select[name$="[parent_question_id]"]')
      const parentId = (parentSelect?.value || "").trim()
      if (parentId.length !== 0) return

      const textValue = this.questionTextForOrder(node)
      const reflectionBaseKey = this.reflectionBaseKey(textValue)

      if (reflectionBaseKey) {
        const existing = reflectionNodesByBaseKey.get(reflectionBaseKey) || []
        existing.push(node)
        reflectionNodesByBaseKey.set(reflectionBaseKey, existing)
        return
      }

      parentNodes.push(node)
    })

    // Reflection questions should follow their base competency question.
    const orderedParentNodes = []
    parentNodes.forEach((node) => {
      orderedParentNodes.push(node)
      const baseKey = this.questionTextKey(this.questionTextForOrder(node))
      const reflections = reflectionNodesByBaseKey.get(baseKey) || []
      reflections.forEach((reflectionNode) => orderedParentNodes.push(reflectionNode))
      reflectionNodesByBaseKey.delete(baseKey)
    })

    // Keep orphan reflections stable at the end when no base question is found.
    reflectionNodesByBaseKey.forEach((nodes) => {
      nodes.forEach((node) => unmatchedReflectionNodes.push(node))
    })
    orderedParentNodes.push(...unmatchedReflectionNodes)

    orderedParentNodes.forEach((node) => {
      parentIndex += 1
      const orderInput = node.querySelector('input[name$="[question_order]"]')
      if (orderInput) orderInput.value = String(parentIndex)

      const idInput = node.querySelector('input[name$="[id]"]')
      const questionId = (idInput?.value || "").trim()
      if (questionId.length) parentOrderById.set(questionId, parentIndex)
    })

    // Sub-questions: order within each parent by DOM order.
    const subCounters = new Map()

    items.forEach((node) => {
      const parentSelect = node.querySelector('select[name$="[parent_question_id]"]')
      const parentId = (parentSelect?.value || "").trim()
      if (parentId.length === 0) return

      const parentOrder = parentOrderById.get(parentId)
      const orderInput = node.querySelector('input[name$="[question_order]"]')
      if (orderInput && parentOrder) orderInput.value = String(parentOrder)

      const next = (subCounters.get(parentId) || 0) + 1
      subCounters.set(parentId, next)
      const subOrderInput = node.querySelector('input[name$="[sub_question_order]"]')
      if (subOrderInput) subOrderInput.value = String(next)
    })
  }

  questionTextForOrder(questionNode) {
    if (!questionNode) return ""
    const textInput = questionNode.querySelector('textarea[name$="[question_text]"]')
    return String(textInput?.value || "").trim()
  }

  questionTextKey(value) {
    return String(value || "").trim().replace(/\s+/g, " ").toLowerCase()
  }

  reflectionBaseKey(value) {
    const text = String(value || "").trim()
    const match = text.match(/^(.+?)\s+Reflection$/i)
    if (!match) return ""
    return this.questionTextKey(match[1])
  }

  handleInput(event) {
    const el = event?.target
    if (!el) return

    // Section title or category name changes should update nav immediately.
    if (
      el.matches('input[name$="[title]"]') ||
      el.matches('input[name$="[name]"]') ||
      el.matches('textarea[name$="[question_text]"]')
    ) {
      this.queueRefresh()
    }
  }

  handleChange(event) {
    const el = event?.target
    if (!el) return

    // Any structural dropdown changes can affect what the user expects next.
    if (el.matches('select[name$="[section_form_uid]"]')) {
      const categoryEl = el.closest("[data-builder-kind='category']")
      if (categoryEl) {
        const selected = (el.value || "").trim()
        this.moveCategoryToSectionGroup(categoryEl, selected)
        this.renumberCategories()
      }
      this.queueRefresh()
    }

    // When a question is turned into a sub-question (or vice versa), update the
    // visual indentation and keep it positioned under its parent immediately.
    if (el.matches('select[name$="[parent_question_id]"]')) {
      this.handleParentQuestionChange(el)
    }
  }

  handleParentQuestionChange(selectEl) {
    const questionEl = selectEl?.closest('[data-question-fields-target="item"]')
    if (!questionEl) return

    const categoryEl = questionEl.closest("[data-builder-kind='category']")
    if (!categoryEl) return

    const list = categoryEl.querySelector('[data-question-fields-target="container"]')
    if (!list) return

    const parentId = (selectEl.value || "").trim()

    if (parentId.length > 0) {
      questionEl.classList.add("ml-6")
      this.placeSubQuestionAfterParent(list, parentId, questionEl)
    } else {
      questionEl.classList.remove("ml-6")
      this.placeParentQuestionAtEnd(list, questionEl)
    }

    this.renumberQuestionsInCategory(categoryEl)
    this.queueRefresh()
  }

  placeParentQuestionAtEnd(listEl, questionEl) {
    if (!listEl || !questionEl) return

    const items = Array.from(listEl.querySelectorAll('[data-question-fields-target="item"]')).filter((n) => !this.isHidden(n))

    // Move after the last parent question (i.e., parent_question_id blank).
    let insertAfter = null
    items.forEach((node) => {
      if (node === questionEl) return
      const select = node.querySelector('select[name$="[parent_question_id]"]')
      const selected = (select?.value || "").trim()
      if (selected.length === 0) insertAfter = node
    })

    if (insertAfter && insertAfter.parentNode === listEl) {
      listEl.insertBefore(questionEl, insertAfter.nextSibling)
    } else {
      // No parents found; place at the top.
      listEl.insertBefore(questionEl, listEl.firstChild)
    }
  }

  queueRefresh() {
    if (this._refreshQueued) return
    this._refreshQueued = true
    requestAnimationFrame(() => {
      this._refreshQueued = false
      this.refresh()
    })
  }

  addSection(event) {
    event?.preventDefault()
    const btn = this.element.querySelector('[data-action="section-fields#add"]')
    if (btn) btn.click()

    // allow DOM to update first
    setTimeout(() => {
      this.refresh()
      this.scrollToLast("section")
    }, 0)
  }

  addCategory(event) {
    event?.preventDefault()
    const btn = this.element.querySelector('[data-action="category-fields#add"]')
    if (btn) btn.click()

    setTimeout(() => {
      this.refresh()
      const id = this.getLastVisibleCategoryId()
      if (id) {
        this.activeCategoryId = id
        const categoryEl = document.getElementById(id)
        const sectionUid = this.sectionUidForCategory(categoryEl)
        if (sectionUid) this.activeSectionId = sectionUid
      }
      this.applyFocusMode()
      this.scrollToLast("category")
    }, 0)
  }

  addQuestion(event) {
    event?.preventDefault()

    const categoryId = this.activeCategoryId || this.getLastVisibleCategoryId()
    if (!categoryId) return

    const categoryEl = document.getElementById(categoryId)
    if (!categoryEl) return

    const addBtn = categoryEl.querySelector('[data-action="question-fields#add"]')
    if (!addBtn) return

    addBtn.click()

    setTimeout(() => {
      this.refresh()
      this.scrollToNewQuestionInCategory(categoryEl)
    }, 0)
  }

  toggleFocusMode(event) {
    event?.preventDefault()
    this.focusModeEnabled = !this.focusModeEnabled
    this.updateFocusModeUi()
    this.applyFocusMode()
  }

  expandAll(event) {
    event?.preventDefault()
    this.focusModeEnabled = false
    this.updateFocusModeUi()
    this.applyFocusMode()
  }

  openReference(event) {
    event?.preventDefault()
    this.lastFocusedElementBeforeReference = document.activeElement
    this.referenceOpen = true
    this.syncReferencePanelUi()
    this.focusReferencePanelFirstElement()
  }

  closeReference(event) {
    event?.preventDefault()
    this.referenceOpen = false
    this.syncReferencePanelUi()

    if (this.lastFocusedElementBeforeReference && typeof this.lastFocusedElementBeforeReference.focus === "function") {
      this.lastFocusedElementBeforeReference.focus()
    } else if (this.hasReferenceToggleButtonTarget) {
      this.referenceToggleButtonTarget.focus()
    }
  }

  toggleSection(event) {
    event?.preventDefault()
    const id = (event?.currentTarget?.dataset?.sectionId || "").trim()
    if (!id) return

    if (this.focusModeEnabled) {
      this.activeSectionId = id
      const firstCategory = this.firstCategoryInSection(id)
      if (firstCategory) this.activeCategoryId = firstCategory
      this.applyFocusMode()
      this.setActiveNav("section", id)
      if (this.activeCategoryId) this.setActiveNav("category", this.activeCategoryId)
      return
    }

    const sectionEl = document.getElementById(id)
    if (!sectionEl) return
    sectionEl.classList.toggle("is-collapsed")
  }

  toggleCategory(event) {
    event?.preventDefault()
    const id = (event?.currentTarget?.dataset?.categoryId || "").trim()
    if (!id) return

    if (this.focusModeEnabled) {
      this.activeCategoryId = id
      const categoryEl = document.getElementById(id)
      const sectionUid = this.sectionUidForCategory(categoryEl)
      if (sectionUid) this.activeSectionId = sectionUid
      this.applyFocusMode()
      if (this.activeSectionId) this.setActiveNav("section", this.activeSectionId)
      this.setActiveNav("category", id)
      return
    }

    const categoryEl = document.getElementById(id)
    if (!categoryEl) return
    categoryEl.classList.toggle("is-collapsed")
  }

  filterOutline() {
    this.applyOutlineFilter()
  }

  addSubQuestion(event) {
    event?.preventDefault()

    const trigger = event?.currentTarget
    const parentId = (trigger?.dataset?.parentQuestionId || "").trim()
    if (!parentId.length) return

    const categoryEl = trigger.closest("[data-builder-kind='category']")
    if (!categoryEl) return

    const addBtn = categoryEl.querySelector('[data-action="question-fields#add"]')
    if (!addBtn) return

    addBtn.click()

    setTimeout(() => {
      const list = categoryEl.querySelector('[data-question-fields-target="container"]')
      if (!list) return

      const items = Array.from(list.querySelectorAll('[data-question-fields-target="item"]')).filter((n) => !this.isHidden(n))
      const newItem = items[items.length - 1]
      if (!newItem) return

      const parentSelect = newItem.querySelector('select[name$="[parent_question_id]"]')
      if (parentSelect) {
        parentSelect.disabled = false
        parentSelect.value = parentId
        parentSelect.dispatchEvent(new Event("change", { bubbles: true }))
      }

      this.placeSubQuestionAfterParent(list, parentId, newItem)
      this.renumberQuestionsInCategory(categoryEl)
      this.queueRefresh()

      if (newItem.id) this.scrollTo(newItem.id)
    }, 0)
  }

  placeSubQuestionAfterParent(listEl, parentId, newItem) {
    if (!listEl || !newItem || !parentId) return

    const items = Array.from(listEl.querySelectorAll('[data-question-fields-target="item"]')).filter((n) => !this.isHidden(n))
    const parentDomId = `question-${parentId}`
    const parentNode = document.getElementById(parentDomId)
    if (!parentNode) return

    let insertAfter = parentNode
    items.forEach((node) => {
      if (node === parentNode) return
      const select = node.querySelector('select[name$="[parent_question_id]"]')
      const selected = (select?.value || "").trim()
      if (selected === parentId) insertAfter = node
    })

    if (insertAfter && insertAfter.parentNode === listEl) {
      listEl.insertBefore(newItem, insertAfter.nextSibling)
    }
  }

  refresh() {
    this.syncCategoryGrouping()
    this.syncBuilderLabels()

    // Ensure order fields stay consistent after other DOM edits.
    this.renumberSections()
    this.renumberCategories()
    const categoryNodes = Array.from(this.categoriesContainerTarget?.querySelectorAll("[data-builder-kind='category']") || []).filter(
      (n) => !this.isHidden(n)
    )
    categoryNodes.forEach((cat) => this.renumberQuestionsInCategory(cat))

    this.buildNav(
      "section",
      this.sectionsNavTarget,
      this.sectionsContainerTarget?.querySelectorAll("[data-builder-kind='section']")
    )

    this.buildLayoutTree(this.categoriesNavTarget)

    this.ensureActiveContext()
    this.applyFocusMode()
    this.applyOutlineFilter()

    // After rebuilding, re-hook observers.
    this.setupObservers()
  }

  syncCategoryGrouping() {
    const root = this.categoriesContainerTarget || this.element
    const categories = Array.from(root.querySelectorAll("[data-builder-kind='category']")).filter((n) => !this.isHidden(n))
    categories.forEach((categoryEl) => {
      const select = categoryEl.querySelector('select[name$="[section_form_uid]"]')
      const selected = (select?.value || "").trim()
      this.moveCategoryToSectionGroup(categoryEl, selected)
    })
  }

  moveCategoryToSectionGroup(categoryEl, sectionUid) {
    if (!categoryEl) return

    const root = this.categoriesContainerTarget || this.element

    let targetList = null
    if (!sectionUid) {
      targetList = root.querySelector("[data-no-section-group-list]") || root.querySelector("[data-no-section-group]")
    } else {
      const sectionEl = document.getElementById(sectionUid)
      if (sectionEl) {
        targetList = sectionEl.querySelector("[data-category-group-list]")
      }
    }

    if (!targetList) {
      targetList = root.querySelector("[data-no-section-group-list]") || root.querySelector("[data-no-section-group]")
    }
    if (!targetList) return
    if (categoryEl.parentElement === targetList) return

    targetList.appendChild(categoryEl)
  }

  syncBuilderLabels() {
    // Keep labels in sync with what the user is typing.
    const sections = Array.from(this.sectionsContainerTarget?.querySelectorAll("[data-builder-kind='section']") || [])
    sections.forEach((node) => {
      const titleInput = node.querySelector('input[name$="[title]"]')
      const value = titleInput?.value?.trim() || ""
      node.dataset.builderLabel = value.length ? value : "Untitled section"
    })

    const categories = Array.from(this.categoriesContainerTarget?.querySelectorAll("[data-builder-kind='category']") || [])
    categories.forEach((node) => {
      const nameInput = node.querySelector('input[name$="[name]"]')
      const value = nameInput?.value?.trim() || ""
      node.dataset.builderLabel = value.length ? value : "Untitled category"
    })

    const questions = Array.from(this.categoriesContainerTarget?.querySelectorAll("[data-builder-kind='question']") || [])
    questions.forEach((node) => {
      const prompt = node.querySelector('textarea[name$="[question_text]"]')
      const value = prompt?.value?.trim() || ""
      node.dataset.builderLabel = value.length ? value : "Untitled question"
    })
  }

  buildLayoutTree(navEl) {
    if (!navEl) return
    navEl.innerHTML = ""

    const sectionNodes = Array.from(this.sectionsContainerTarget?.querySelectorAll("[data-builder-kind='section']") || []).filter(
      (n) => !this.isHidden(n)
    )
    const categoryNodes = Array.from(this.categoriesContainerTarget?.querySelectorAll("[data-builder-kind='category']") || []).filter(
      (n) => !this.isHidden(n)
    )

    if (sectionNodes.length === 0 && categoryNodes.length === 0) {
      const empty = document.createElement("p")
      empty.className = "text-xs text-slate-500"
      empty.textContent = "No categories yet."
      navEl.appendChild(empty)
      return
    }

    // Map of section uid -> label, preserving DOM order.
    const sectionList = sectionNodes.map((node) => ({
      uid: node.id,
      label: (node.dataset.builderLabel || "").trim() || "Untitled section"
    }))
    const sectionLabelByUid = new Map(sectionList.map((s) => [s.uid, s.label]))

    // Group categories by section assignment (select value).
    const groups = new Map()
    const noSectionKey = "__NO_SECTION__"
    groups.set(noSectionKey, [])
    sectionList.forEach((s) => groups.set(s.uid, []))

    categoryNodes.forEach((cat) => {
      const select = cat.querySelector('select[name$="[section_form_uid]"]')
      const selected = (select?.value || "").trim()
      const key = selected && groups.has(selected) ? selected : noSectionKey
      groups.get(key).push(cat)
    })

    const renderSectionHeader = (label, targetId, isNoSection = false) => {
      const row = document.createElement("div")
      row.className = "mt-2"

      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = "u-w-full rounded-lg px-2 py-2 text-left text-xs font-semibold uppercase tracking-wide text-slate-500 hover:bg-slate-50"
      btn.dataset.builderNavLabel = label.toLowerCase()
      const icon = document.createElement("span")
      icon.setAttribute("aria-hidden", "true")
      icon.textContent = isNoSection ? "⛔" : "🧩"
      const text = document.createElement("span")
      text.textContent = label
      btn.append(icon, text)
      if (!isNoSection && targetId) {
        btn.addEventListener("click", () => {
          this.setActiveNav("section", targetId)
          this.activeSectionId = targetId
          const firstCategory = this.firstCategoryInSection(targetId)
          if (firstCategory) {
            this.activeCategoryId = firstCategory
            this.setActiveNav("category", firstCategory)
          }
          this.applyFocusMode()
          this.scrollTo(targetId)
        })
      }

      row.appendChild(btn)
      navEl.appendChild(row)
    }

    const renderCategory = (categoryNode) => {
      const categoryId = categoryNode.id
      const categoryLabel = (categoryNode.dataset.builderLabel || "").trim() || "Untitled category"

      const catBtn = document.createElement("button")
      catBtn.type = "button"
      catBtn.className = "flex u-w-full items-center gap-2 rounded-lg px-2 py-2 text-left text-sm text-slate-700 hover:bg-slate-50"
      catBtn.dataset.builderNavKind = "category"
      catBtn.dataset.builderNavTargetId = categoryId
      catBtn.dataset.builderNavLabel = categoryLabel.toLowerCase()
      const catIcon = document.createElement("span")
      catIcon.setAttribute("aria-hidden", "true")
      catIcon.textContent = "🗂️"
      const catText = document.createElement("span")
      catText.textContent = categoryLabel
      catBtn.append(catIcon, catText)
      catBtn.addEventListener("click", () => {
        this.setActiveNav("category", categoryId)
        const sectionUid = this.sectionUidForCategory(categoryNode)
        if (sectionUid) {
          this.activeSectionId = sectionUid
          this.setActiveNav("section", sectionUid)
        }
        this.applyFocusMode()
        this.scrollTo(categoryId)
      })
      navEl.appendChild(catBtn)

      const questionNodes = Array.from(categoryNode.querySelectorAll("[data-builder-kind='question']")).filter((n) => !this.isHidden(n))
      questionNodes.forEach((q) => {
        const qId = q.id
        if (!qId) return
        const qLabel = (q.dataset.builderLabel || "").trim() || "Untitled question"

        const parentSelect = q.querySelector('select[name$="[parent_question_id]"]')
        const isSubQuestion = ((parentSelect?.value || "").trim().length > 0)

        const qBtn = document.createElement("button")
        qBtn.type = "button"
        qBtn.className = "flex u-w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left text-xs text-slate-600 hover:bg-slate-50"
        qBtn.dataset.builderNavKind = "question"
        qBtn.dataset.builderNavTargetId = qId
        qBtn.dataset.builderNavLabel = qLabel.toLowerCase()
        qBtn.style.paddingLeft = isSubQuestion ? "2rem" : "1.25rem"
        const qIcon = document.createElement("span")
        qIcon.setAttribute("aria-hidden", "true")
        qIcon.textContent = isSubQuestion ? "↳" : "❓"
        const qText = document.createElement("span")
        qText.textContent = qLabel
        qBtn.append(qIcon, qText)
        qBtn.addEventListener("click", () => {
          this.setActiveNav("question", qId)
          this.setActiveNav("category", categoryId)
          this.activeCategoryId = categoryId
          const sectionUid = this.sectionUidForCategory(categoryNode)
          if (sectionUid) {
            this.activeSectionId = sectionUid
            this.setActiveNav("section", sectionUid)
          }
          this.applyFocusMode()
          this.scrollTo(qId)
        })

        navEl.appendChild(qBtn)
      })
    }

    // Render: sections in order, plus a No section group at the end if needed.
    sectionList.forEach((section) => {
      const cats = groups.get(section.uid) || []
      if (cats.length === 0) return
      renderSectionHeader(section.label, section.uid)
      cats.forEach(renderCategory)
    })

    const noSectionCats = groups.get(noSectionKey) || []
    if (noSectionCats.length > 0) {
      renderSectionHeader("No section", null, true)
      noSectionCats.forEach(renderCategory)
    }

    // Re-apply active highlight after rebuilding the nav.
    if (this.activeCategoryId) this.setActiveNav("category", this.activeCategoryId)
    if (this.activeQuestionId) this.setActiveNav("question", this.activeQuestionId)
  }

  buildNav(kind, navEl, nodes) {
    if (!navEl) return

    const items = Array.from(nodes || []).filter((node) => !this.isHidden(node))
    navEl.innerHTML = ""

    if (items.length === 0) {
      const empty = document.createElement("p")
      empty.className = "text-xs text-slate-500"
      empty.textContent = kind === "section" ? "No sections yet." : "No categories yet."
      navEl.appendChild(empty)
      return
    }

    items.forEach((node) => {
      const id = node.getAttribute("id")
      if (!id) return

      const label = (node.dataset.builderLabel || "").trim() || (kind === "section" ? "Untitled section" : "Untitled category")

      const a = document.createElement("button")
      a.type = "button"
      a.className = "flex u-w-full items-center gap-2 rounded-lg px-2 py-2 text-left text-sm text-slate-700 hover:bg-slate-50"
      a.dataset.builderNavKind = kind
      a.dataset.builderNavTargetId = id
      a.dataset.builderNavLabel = label.toLowerCase()
      const icon = document.createElement("span")
      icon.setAttribute("aria-hidden", "true")
      icon.textContent = kind === "section" ? "🧩" : "🗂️"
      const text = document.createElement("span")
      text.textContent = label
      a.append(icon, text)
      a.addEventListener("click", () => {
        this.setActiveNav(kind, id)
        if (kind === "section") {
          this.activeSectionId = id
          const firstCategory = this.firstCategoryInSection(id)
          if (firstCategory) {
            this.activeCategoryId = firstCategory
            this.setActiveNav("category", firstCategory)
          }
        }
        this.applyFocusMode()
        this.scrollTo(id)
      })

      navEl.appendChild(a)
    })

    // Re-apply active highlight after rebuilding the nav.
    if (kind === "category" && this.activeCategoryId) this.setActiveNav("category", this.activeCategoryId)
  }

  setupObservers() {
    const sectionNodes = Array.from(this.sectionsContainerTarget?.querySelectorAll("[data-builder-kind='section']") || []).filter(
      (n) => !this.isHidden(n)
    )
    const categoryNodes = Array.from(this.categoriesContainerTarget?.querySelectorAll("[data-builder-kind='category']") || []).filter(
      (n) => !this.isHidden(n)
    )

    if (this._sectionObserver) this._sectionObserver.disconnect()
    if (this._categoryObserver) this._categoryObserver.disconnect()

    const observerOptions = { root: null, threshold: 0.35 }

    this._sectionObserver = new IntersectionObserver((entries) => {
      const visible = entries
        .filter((e) => e.isIntersecting)
        .sort((a, b) => (b.intersectionRatio || 0) - (a.intersectionRatio || 0))[0]

      if (!visible?.target?.id) return
      this.setActiveNav("section", visible.target.id)
    }, observerOptions)

    this._categoryObserver = new IntersectionObserver((entries) => {
      const visible = entries
        .filter((e) => e.isIntersecting)
        .sort((a, b) => (b.intersectionRatio || 0) - (a.intersectionRatio || 0))[0]

      if (!visible?.target?.id) return
      this.setActiveNav("category", visible.target.id)
    }, observerOptions)

    sectionNodes.forEach((node) => this._sectionObserver.observe(node))
    categoryNodes.forEach((node) => this._categoryObserver.observe(node))
  }

  setActiveNav(kind, id) {
    const root = kind === "section" ? this.sectionsNavTarget : this.categoriesNavTarget
    if (!root) return

    if (kind === "section") this.activeSectionId = id
    if (kind === "category") this.activeCategoryId = id
    if (kind === "question") {
      this.activeQuestionId = id
      window.dispatchEvent(new CustomEvent("survey-item:activate", { detail: { id } }))
    }

    Array.from(root.querySelectorAll("button[data-builder-nav-kind]")).forEach((btn) => {
      const isActive = btn.dataset.builderNavTargetId === id
      btn.classList.toggle("bg-indigo-50", isActive)
      btn.classList.toggle("text-indigo-700", isActive)
      btn.classList.toggle("font-semibold", isActive)
    })
  }

  scrollTo(id) {
    const el = document.getElementById(id)
    if (!el) return

    el.scrollIntoView({ behavior: "smooth", block: "start" })
  }

  scrollToLast(kind) {
    const nodes = Array.from(this.element.querySelectorAll(`[data-builder-kind='${kind}']`)).filter((n) => !this.isHidden(n))
    const last = nodes[nodes.length - 1]
    if (last?.id) this.scrollTo(last.id)
  }

  getLastVisibleCategoryId() {
    const nodes = Array.from(this.element.querySelectorAll("[data-builder-kind='category']")).filter((n) => !this.isHidden(n))
    const last = nodes[nodes.length - 1]
    return last?.id || null
  }

  scrollToNewQuestionInCategory(categoryEl) {
    if (!categoryEl) return
    const items = Array.from(categoryEl.querySelectorAll('[data-question-fields-target="item"]')).filter((n) => !this.isHidden(n))
    const last = items[items.length - 1]
    if (last) {
      last.scrollIntoView({ behavior: "smooth", block: "center" })
      return
    }
    // fallback
    if (categoryEl.id) this.scrollTo(categoryEl.id)
  }

  isHidden(el) {
    if (!el) return true
    if (el.style?.display === "none") return true
    if (el.closest("[style*='display: none']")) return true
    return false
  }

  ensureActiveContext() {
    const sectionNodes = Array.from(this.sectionsContainerTarget?.querySelectorAll("[data-builder-kind='section']") || []).filter(
      (n) => !this.isHidden(n)
    )
    const categoryNodes = Array.from(this.categoriesContainerTarget?.querySelectorAll("[data-builder-kind='category']") || []).filter(
      (n) => !this.isHidden(n)
    )

    const sectionIds = new Set(sectionNodes.map((n) => n.id).filter(Boolean))
    const categoryIds = new Set(categoryNodes.map((n) => n.id).filter(Boolean))

    if (!this.activeSectionId || !sectionIds.has(this.activeSectionId)) {
      this.activeSectionId = sectionNodes[0]?.id || null
    }

    if (!this.activeCategoryId || !categoryIds.has(this.activeCategoryId)) {
      this.activeCategoryId = this.firstCategoryInSection(this.activeSectionId) || categoryNodes[0]?.id || null
    }

    if (this.activeCategoryId) {
      const categoryEl = document.getElementById(this.activeCategoryId)
      const sectionUid = this.sectionUidForCategory(categoryEl)
      if (sectionUid) this.activeSectionId = sectionUid
    }

    if (this.activeSectionId) this.setActiveNav("section", this.activeSectionId)
    if (this.activeCategoryId) this.setActiveNav("category", this.activeCategoryId)
  }

  firstCategoryInSection(sectionUid) {
    const categories = Array.from(this.categoriesContainerTarget?.querySelectorAll("[data-builder-kind='category']") || []).filter(
      (n) => !this.isHidden(n)
    )
    const selected = categories.find((cat) => this.sectionUidForCategory(cat) === sectionUid)
    return selected?.id || null
  }

  sectionUidForCategory(categoryEl) {
    if (!categoryEl) return ""
    const select = categoryEl.querySelector('select[name$="[section_form_uid]"]')
    return (select?.value || "").trim()
  }

  applyFocusMode() {
    const sectionNodes = Array.from(this.sectionsContainerTarget?.querySelectorAll("[data-builder-kind='section']") || []).filter(
      (n) => !this.isHidden(n)
    )
    const categoryNodes = Array.from(this.categoriesContainerTarget?.querySelectorAll("[data-builder-kind='category']") || [])

    this.applyCategoryFocus(categoryNodes)

    const visibleCategoryNodes = categoryNodes.filter((n) => !this.isHidden(n))

    if (!this.focusModeEnabled) {
      sectionNodes.forEach((node) => node.classList.remove("is-collapsed"))
      visibleCategoryNodes.forEach((node) => node.classList.remove("is-collapsed"))
      return
    }

    const activeSection = this.activeSectionId
    const activeCategory = this.activeCategoryId

    sectionNodes.forEach((sectionNode) => {
      const sectionId = sectionNode.id
      const shouldExpand = !!activeSection && sectionId === activeSection
      sectionNode.classList.toggle("is-collapsed", !shouldExpand)
    })

    visibleCategoryNodes.forEach((categoryNode) => {
      const categoryId = categoryNode.id
      const categorySectionUid = this.sectionUidForCategory(categoryNode)
      const inActiveSection = !activeSection || categorySectionUid === activeSection
      const shouldExpand = inActiveSection && categoryId === activeCategory
      categoryNode.classList.toggle("is-collapsed", !shouldExpand)
    })
  }

  applyCategoryFocus(categoryNodes) {
    const targetId = this.activeCategoryId

    categoryNodes.forEach((node) => {
      if (!targetId) {
        node.classList.remove("is-builder-hidden")
        return
      }

      const shouldShow = node.id === targetId
      node.classList.toggle("is-builder-hidden", !shouldShow)
    })
  }

  updateFocusModeUi() {
    if (!this.hasFocusModeButtonTarget) return
    this.focusModeButtonTarget.textContent = `Focus mode: ${this.focusModeEnabled ? "On" : "Off"}`
    this.focusModeButtonTarget.classList.toggle("btn-primary", this.focusModeEnabled)
    this.focusModeButtonTarget.classList.toggle("btn-secondary", !this.focusModeEnabled)
  }

  syncReferencePanelUi() {
    if (!this.hasReferencePanelTarget || !this.hasReferenceBackdropTarget) return

    this.referencePanelTarget.classList.toggle("hidden", !this.referenceOpen)
    this.referenceBackdropTarget.classList.toggle("hidden", !this.referenceOpen)
    this.referencePanelTarget.setAttribute("aria-hidden", this.referenceOpen ? "false" : "true")

    if (this.hasReferenceToggleButtonTarget) {
      this.referenceToggleButtonTarget.textContent = this.referenceOpen ? "Close reference" : "Open reference"
    }
  }

  handleDocumentKeydown(event) {
    if (!this.referenceOpen || !this.hasReferencePanelTarget) return

    if (event.key === "Escape") {
      event.preventDefault()
      this.closeReference()
      return
    }

    if (event.key !== "Tab") return

    const focusable = this.getReferencePanelFocusableElements()
    if (!focusable.length) {
      event.preventDefault()
      this.referencePanelTarget.focus()
      return
    }

    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    const active = document.activeElement

    if (event.shiftKey && active === first) {
      event.preventDefault()
      last.focus()
      return
    }

    if (!event.shiftKey && active === last) {
      event.preventDefault()
      first.focus()
    }
  }

  focusReferencePanelFirstElement() {
    if (!this.hasReferencePanelTarget) return

    const focusable = this.getReferencePanelFocusableElements()
    if (focusable.length) {
      focusable[0].focus()
    } else {
      this.referencePanelTarget.focus()
    }
  }

  getReferencePanelFocusableElements() {
    if (!this.hasReferencePanelTarget) return []

    const selector = [
      "button:not([disabled])",
      "a[href]",
      "input:not([disabled])",
      "select:not([disabled])",
      "textarea:not([disabled])",
      "[tabindex]:not([tabindex='-1'])"
    ].join(",")

    return Array.from(this.referencePanelTarget.querySelectorAll(selector)).filter((el) => !this.isHidden(el))
  }

  applyOutlineFilter() {
    const query = this.hasNavSearchInputTarget ? this.navSearchInputTarget.value.toLowerCase().trim() : ""
    const roots = [this.sectionsNavTarget, this.categoriesNavTarget].filter(Boolean)

    roots.forEach((root) => {
      const buttons = Array.from(root.querySelectorAll("button[data-builder-nav-label]"))
      buttons.forEach((btn) => {
        if (!query.length) {
          btn.style.display = ""
          return
        }

        const label = btn.dataset.builderNavLabel || ""
        const isMatch = label.includes(query)
        const kind = btn.dataset.builderNavKind || ""

        // Keep section headers visible for orientation; aggressively filter others.
        if (!kind.length || kind === "section") {
          btn.style.display = ""
        } else {
          btn.style.display = isMatch ? "" : "none"
        }
      })
    })
  }
}
