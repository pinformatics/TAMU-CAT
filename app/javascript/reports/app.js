import React from "react"
import Chart from "chart.js/auto"

const { useCallback, useEffect, useMemo, useRef, useState } = React
const h = React.createElement
const TARGET_SCORE = 4
const EXCEEDS_THRESHOLD = 4.5

const COLORS = {
  student: "#500000",
  advisor: "#2563eb",
  course: "#c2410c",
  achieved: "#16a34a",
  notMet: "#dc2626",
  exceeds: "#6366f1",
  notAssessed: "#94a3b8",
  neutralText: "#0f172a"
}

const STATUS_LABELS = {
  achieved: "Meets target",
  not_met: "Below target",
  exceeds: "Exceeds target",
  not_assessed: "Not assessed"
}

const STATUS_COLOR_MAP = {
  exceeds: COLORS.exceeds,
  achieved: COLORS.achieved,
  not_met: COLORS.notMet,
  not_assessed: COLORS.notAssessed
}

let percentagePluginRegistered = false

const percentageLabelPlugin = {
  id: "percentageLabelPlugin",
  afterDatasetsDraw(chart, _, options) {
    const ctx = chart.ctx
    chart.data.datasets.forEach((dataset, datasetIndex) => {
      if (!dataset || !dataset.showDataLabels) return
      const meta = chart.getDatasetMeta(datasetIndex)
      meta.data.forEach((element, index) => {
        const value = dataset.data[index]
        if (value === null || value === undefined) return
        const numeric = Number(value)
        if (!Number.isFinite(numeric) || numeric <= 0) return
        const { x, y } = element.tooltipPosition()
        ctx.save()
        ctx.fillStyle = (options && options.color) || COLORS.neutralText
        ctx.font = (options && options.font) || "12px 'Inter', sans-serif"
        ctx.textAlign = "center"
        ctx.textBaseline = "middle"
        ctx.fillText(`${numeric.toFixed(1)}%`, x, y)
        ctx.restore()
      })
    })
  }
}

if (!percentagePluginRegistered) {
  Chart.register(percentageLabelPlugin)
  percentagePluginRegistered = true
}

const API_ENDPOINTS = {
  filters: "/api/reports/filters",
  benchmark: "/api/reports/benchmark",
  competency: "/api/reports/competency-summary",
  competencyDetail: "/api/reports/competency-detail",
  track: "/api/reports/track-summary",
  employment: "/api/reports/employment-summary"
}

const DEFAULT_FILTERS = {
  track: "all",
  program_year: "all",
  semester: "all",
  advisor_id: "all",
  category_id: "all",
  survey_id: "all",
  student_id: "all",
  competency: "all"
}
const DASHBOARD_FILTER_KEYS = Object.keys(DEFAULT_FILTERS)

const EMPTY_OPTIONS = Object.freeze({
  tracks: [],
  program_years: [],
  semesters: [],
  advisors: [],
  categories: [],
  surveys: [],
  students: [],
  competencies: []
})

const compact = (values) => values.filter(Boolean)

const titleize = (value = "") => {
  const str = String(value).trim()
  if (!str) return ""
  return str
    .toLowerCase()
    .split(/\s+/)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ")
}

const safeNumber = (value) => {
  const numeric = Number(value)
  return Number.isFinite(numeric) ? numeric : null
}

const ratingStatus = (value, { treatZeroAsNotAssessed = false } = {}) => {
  const numeric = safeNumber(value)
  if (numeric === null) return "not_assessed"
  if (treatZeroAsNotAssessed && numeric === 0) return "not_assessed"
  if (numeric >= EXCEEDS_THRESHOLD) return "exceeds"
  if (numeric >= TARGET_SCORE) return "achieved"
  return "not_met"
}

const ratingColor = (status) => {
  switch (status) {
    case "exceeds":
      return COLORS.exceeds
    case "achieved":
      return COLORS.achieved
    case "not_met":
      return COLORS.notMet
    case "not_assessed":
    default:
      return COLORS.notAssessed
  }
}

const statusLabel = (status) => STATUS_LABELS[status] || "Unknown"

const formatMetricValue = (value, unit = "score", precision = 1) => {
  if (value === null || value === undefined) return "—"
  const numeric = Number(value)
  if (!Number.isFinite(numeric)) return "—"
  const fixed = numeric.toFixed(precision)
  return unit === "percent" ? `${fixed}%` : fixed
}

const formatChange = (change, unit = "score") => {
  if (change === null || change === undefined) return "—"
  const numeric = Number(change)
  if (!Number.isFinite(numeric)) return "—"
  const prefix = numeric > 0 ? "+" : ""
  const formatted = unit === "percent" ? numeric.toFixed(1) : numeric.toFixed(2)
  return unit === "percent" ? `${prefix}${formatted}pp` : `${prefix}${formatted}`
}

const findOptionLabel = (collection, value, labelKey = "name") => {
  if (!Array.isArray(collection)) return null
  return collection.find((entry) => {
    if (!entry) return false
    const entryId = entry.id ?? entry
    if (entryId === undefined || entryId === null) return false
    if (value === undefined || value === null) return false
    const entryNumeric = Number(entryId)
    const valueNumeric = Number(value)
    if (Number.isFinite(entryNumeric) && Number.isFinite(valueNumeric)) {
      return entryNumeric === valueNumeric
    }
    return String(entryId) === String(value)
  })?.[labelKey]
}

const describeActiveFilters = (filters, options) => {
  const mergedFilters = { ...DEFAULT_FILTERS, ...(filters || {}) }
  const mergedOptions = { ...EMPTY_OPTIONS, ...(options || {}) }
  const parts = []

  if (mergedFilters.track !== "all") {
    parts.push(`Track: ${mergedFilters.track}`)
  }
  if (mergedFilters.program_year !== "all") {
    parts.push(`Year: ${mergedFilters.program_year}`)
  }
  if (mergedFilters.semester !== "all") {
    parts.push(`Semester: ${mergedFilters.semester}`)
  }
  if (mergedFilters.advisor_id !== "all") {
    const label = findOptionLabel(mergedOptions.advisors, mergedFilters.advisor_id)
    parts.push(`Advisor: ${label || mergedFilters.advisor_id}`)
  }
  if (mergedFilters.category_id !== "all") {
    const label = findOptionLabel(mergedOptions.categories, mergedFilters.category_id)
    parts.push(`Domain: ${label || mergedFilters.category_id}`)
  }
  if (mergedFilters.competency !== "all") {
    const label = findOptionLabel(mergedOptions.competencies, mergedFilters.competency)
    parts.push(`Competency: ${label || mergedFilters.competency}`)
  }
  if (mergedFilters.survey_id !== "all") {
    const survey = mergedOptions.surveys.find((entry) => Number(entry?.id) === Number(mergedFilters.survey_id))
    const label = survey ? compact([survey.title, survey.semester]).join(" · ") : mergedFilters.survey_id
    parts.push(`Survey: ${label}`)
  }
  if (mergedFilters.student_id !== "all") {
    const label = findOptionLabel(mergedOptions.students, mergedFilters.student_id)
    parts.push(`Student: ${label || mergedFilters.student_id}`)
  }

  return parts.length > 0 ? parts.join(", ") : "None"
}

const buildQueryString = (filters) => {
  const params = new URLSearchParams()
  Object.entries(filters || {}).forEach(([ key, value ]) => {
    if (value && value !== "all") {
      params.append(key, value)
    }
  })
  const query = params.toString()
  return query ? `?${query}` : ""
}

const buildUrlWithQuery = (baseUrl, filters) => {
  if (!baseUrl) return ""

  const query = buildQueryString(filters)
  if (!query) return baseUrl

  return `${baseUrl}${baseUrl.includes("?") ? "&" : "?"}${query.slice(1)}`
}

const normalizeDashboardFilters = (filters = {}) => {
  const normalized = { ...DEFAULT_FILTERS }

  DASHBOARD_FILTER_KEYS.forEach((key) => {
    const value = filters[key]
    if (value !== undefined && value !== null && String(value).trim() !== "") {
      normalized[key] = String(value)
    }
  })

  return normalized
}

const updatePrimaryDashboardDownload = (filters) => {
  const links = document.querySelectorAll("[data-report-primary-download='true']")
  if (!links.length) return

  links.forEach((link) => {
    const baseUrl = link.dataset.reportDownloadBaseUrl || link.href
    link.href = buildUrlWithQuery(baseUrl, filters)
  })
}

const syncDashboardUrl = (filters) => {
  if (!window.history || !window.location) return

  const url = new URL(window.location.href)
  url.searchParams.set("report_tab", "dashboard")
  DASHBOARD_FILTER_KEYS.forEach((key) => url.searchParams.delete(key))

  Object.entries(filters || {}).forEach(([ key, value ]) => {
    if (value && value !== "all") {
      url.searchParams.set(key, value)
    }
  })

  window.history.replaceState({}, "", url)
}

const fetchJson = async (url) => {
  const response = await fetch(url, {
    credentials: "same-origin",
    headers: { Accept: "application/json" }
  })

  if (!response.ok) {
    const message = await response.text()
    throw new Error(message || `Request failed with status ${response.status}`)
  }

  return response.json()
}

const LoadingState = () =>
  h("div", { className: "flex h-80 items-center justify-center rounded-2xl bg-white shadow-sm ring-1 ring-slate-200", role: "status", "aria-live": "polite" }, [
    h("div", { className: "flex flex-col items-center gap-4" }, [
      h("div", { className: "h-12 w-12 animate-spin rounded-full border-4 border-amber-500 border-t-transparent", "aria-hidden": "true" }),
      h("p", { className: "text-sm font-medium text-slate-600" }, "Loading analytics...")
    ])
  ])

const ErrorState = ({ message, onRetry }) => {
  const children = [
    h("h2", null, "We hit a snag"),
    h("p", null, message)
  ]

  if (onRetry) {
    children.push(
      h("button", {
        type: "button",
        className: "btn btn-primary",
        onClick: onRetry
      }, "Try again")
    )
  }

  return h("div", { className: "c-analytics-panel c-analytics-panel--error", role: "alert" }, children)
}

const FilterBar = ({ filters, options, onChange, onReset }) => {
  const mergedFilters = { ...DEFAULT_FILTERS, ...(filters || {}) }
  const mergedOptions = { ...EMPTY_OPTIONS, ...(options || {}) }

  const handleChange = (event) => {
    const { name, value } = event.target
    onChange({ ...mergedFilters, [name]: value })
  }

  const surveyLabel = (survey) => compact([ survey.title, survey.semester ]).join(" · ")

  const selectConfigs = [
    {
      name: "track",
      label: "Track",
      defaultLabel: "All tracks",
      list: mergedOptions.tracks,
      getValue: (value) => value,
      getLabel: (value) => titleize(value)
    },
    {
      name: "program_year",
      label: "Year",
      defaultLabel: "All years",
      list: mergedOptions.program_years,
      getValue: (value) => value,
      getLabel: (value) => value
    },
    {
      name: "semester",
      label: "Semester",
      defaultLabel: "All semesters",
      list: mergedOptions.semesters,
      getValue: (value) => value,
      getLabel: (value) => value
    },
    {
      name: "advisor_id",
      label: "Advisor",
      defaultLabel: "All advisors",
      list: mergedOptions.advisors,
      getValue: (advisor) => advisor && advisor.id,
      getLabel: (advisor) => advisor && advisor.name
    },
    {
      name: "category_id",
      label: "Domain",
      defaultLabel: "All domains",
      list: mergedOptions.categories,
      getValue: (category) => category && category.id,
      getLabel: (category) => category && category.name
    },
    {
      name: "competency",
      label: "Competency",
      defaultLabel: "All competencies",
      list: mergedOptions.competencies,
      getValue: (competency) => competency && competency.id,
      getLabel: (competency) => competency && competency.name
    },
    {
      name: "survey_id",
      label: "Survey",
      defaultLabel: "All surveys",
      list: mergedOptions.surveys,
      getValue: (survey) => survey && survey.id,
      getLabel: (survey) => survey && surveyLabel(survey)
    },
    {
      name: "student_id",
      label: "Student",
      defaultLabel: "All students",
      list: mergedOptions.students,
      getValue: (student) => student && student.id,
      getLabel: (student) => student && student.name
    }
  ]

  return h("section", { className: "c-analytics-panel c-analytics-filters", "aria-label": "Dashboard filters" }, [
    h("div", { className: "c-analytics-filters__grid" },
      selectConfigs.map((config) => {
        const value = mergedFilters[config.name] ?? "all"
        const optionsNodes = [
          h("option", { key: `${config.name}-all`, value: "all" }, config.defaultLabel)
        ]

        config.list.forEach((entry) => {
          if (!entry && entry !== 0) return
          const optionValue = config.getValue(entry)
          const optionLabel = config.getLabel(entry)
          if (optionValue === undefined || optionValue === null) return
          optionsNodes.push(
            h("option", { key: `${config.name}-${optionValue}`, value: String(optionValue) }, optionLabel)
          )
        })

        return h("label", { key: config.name, className: "c-analytics-field" }, [
          h("span", null, config.label),
          h("select", { name: config.name, value, onChange: handleChange }, optionsNodes)
        ])
      })
    ),
    h("button", { type: "button", className: "btn btn-secondary", onClick: onReset }, "Reset filters")
  ])
}

const SummaryCards = ({ cards }) =>
  h("section", { className: "c-analytics-summary" },
    cards
      .filter((card) => !["overall_average", "overall_advisor_average"].includes(card.key))
      .map((card) => {
      const headerChildren = [ h("p", { className: "c-analytics-summary__label" }, card.title) ]
      if (card.meta && card.meta.name) {
        headerChildren.push(h("span", { className: "c-analytics-summary__meta" }, card.meta.name))
      }

        const trackSummaries = Array.isArray(card.meta?.tracks) ? card.meta.tracks : []
        const showTrackSummaries = trackSummaries.length > 0

        let valueNode
        if (showTrackSummaries) {
          const trackRows = trackSummaries.map((track) => {
            const detailParts = []
            if (track.source_label) detailParts.push(track.source_label)
            if (track.students_met_goal !== undefined && track.students_met_goal !== null) {
              detailParts.push(`Students meeting goal: ${track.students_met_goal}`)
            }

            const children = [
              h("span", { className: "c-analytics-summary__meta" }, track.label),
              h("strong", null, formatMetricValue(track.percent, "percent", 0))
            ]

            if (detailParts.length > 0) {
              children.push(
                h("span", { className: "c-analytics-summary__subtext" }, detailParts.join(" • "))
              )
            }

            return h("div", { key: track.label, className: "c-analytics-summary__value-track" }, children)
          })
          valueNode = h("div", { className: "c-analytics-summary__value c-analytics-summary__value--tracks" }, trackRows)
        } else {
          const valueChildren = [ h("strong", null, formatMetricValue(card.value, card.unit, card.precision)) ]
          if (card.meta && card.meta.advisor_average !== undefined && card.meta.advisor_average !== null) {
            valueChildren.push(
              h("span", { className: "c-analytics-summary__subtext" }, `Advisor avg ${formatMetricValue(card.meta.advisor_average, "score", 1)}`)
            )
          }
          valueNode = h("div", { className: "c-analytics-summary__value" }, valueChildren)
        }

      const footerChildren = [
        h("span", { className: `c-analytics-summary__trend c-analytics-summary__trend--${card.change_direction || "flat"}` }, formatChange(card.change, card.unit)),
        h("span", { className: "c-analytics-summary__description" }, card.description)
      ]

      if (card.meta && card.meta.goal_percent) {
        footerChildren.push(
          h("span", { className: "c-analytics-summary__description" }, `Program goal: ${formatMetricValue(card.meta.goal_percent, "percent", 0)}`)
        )
      }
      if (card.meta && card.meta.students_met_goal !== undefined) {
        footerChildren.push(
          h("span", { className: "c-analytics-summary__description" }, `Students meeting goal: ${card.meta.students_met_goal}`)
        )
      }

      return h("article", { key: card.key, className: "c-analytics-summary__card", "aria-label": card.title }, [
        h("header", null, headerChildren),
        valueNode,
        h("footer", null, footerChildren)
      ])
    })
  )

const TrendChart = ({ timeline, yAxisMode }) => {
  const canvasRef = useRef(null)

  useEffect(() => {
    if (!canvasRef.current || !Array.isArray(timeline) || timeline.length === 0) return undefined

    const percentMode = yAxisMode === "percent"
    const metricUnit = percentMode ? "percent" : "score"

    const ctx = canvasRef.current.getContext("2d")
    const chart = new Chart(ctx, {
      type: "line",
      data: {
        labels: timeline.map((point) => point.label),
        datasets: [
          {
            label: "Student",
            data: timeline.map((point) => percentMode ? point.student_target_percent : point.student),
            borderColor: COLORS.student,
            backgroundColor: "rgba(80, 0, 0, 0.15)",
            tension: 0.3,
            borderWidth: 2,
            pointBackgroundColor: COLORS.student,
            pointRadius: 4
          },
          {
            label: "Advisor",
            data: timeline.map((point) => percentMode ? point.advisor_target_percent : point.advisor),
            borderColor: COLORS.advisor,
            backgroundColor: "rgba(37, 99, 235, 0.15)",
            tension: 0.3,
            borderWidth: 2,
            pointBackgroundColor: COLORS.advisor,
            pointRadius: 4
          },
          {
            label: "Course",
            data: timeline.map((point) => percentMode ? point.course_target_percent : point.course),
            borderColor: COLORS.course,
            backgroundColor: "rgba(194, 65, 12, 0.15)",
            tension: 0.3,
            borderWidth: 2,
            pointBackgroundColor: COLORS.course,
            pointRadius: 4
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { position: "top" },
          tooltip: {
            callbacks: {
              label(context) {
                const value = context.raw
                return `${context.dataset.label}: ${formatMetricValue(value, metricUnit, percentMode ? 1 : 2)}`
              }
            }
          }
        },
        scales: {
          y: {
            suggestedMin: 0,
            suggestedMax: percentMode ? 100 : 5,
            ticks: {
              callback(value) {
                return percentMode ? `${Number(value).toFixed(0)}%` : Number(value).toFixed(1)
              }
            }
          }
        }
      }
    })

    return () => chart.destroy()
  }, [ timeline, yAxisMode ])

  const ariaLabel = yAxisMode === "percent" ? "% meeting target over time" : "Monthly average scores"

  return h("div", { className: "c-analytics-chart", role: "img", "aria-label": ariaLabel },
    h("canvas", { ref: canvasRef })
  )
}



const CompetencyAchievementChart = ({ items, yAxisMode }) => {
  const canvasRef = useRef(null)

  useEffect(() => {
    if (!canvasRef.current || !Array.isArray(items) || items.length === 0) return undefined

    const percentMode = yAxisMode === "percent"
    const metricUnit = percentMode ? "percent" : "score"
    const datasets = [
      {
        label: percentMode ? "Student %" : "Student Avg",
        data: items.map((item) => {
          if (percentMode) return safeNumber(item.student_target_percent) ?? 0
          return item.student_average || 0
        }),
        backgroundColor: COLORS.student,
        borderRadius: 6
      },
      {
        label: percentMode ? "Advisor %" : "Advisor Avg",
        data: items.map((item) => {
          if (percentMode) return safeNumber(item.advisor_target_percent) ?? 0
          return item.advisor_average || 0
        }),
        backgroundColor: COLORS.advisor,
        borderRadius: 6
      }
    ]

    datasets.push({
      label: percentMode ? "Course %" : "Course Avg",
      data: items.map((item) => {
        if (percentMode) return safeNumber(item.course_target_percent) ?? 0
        return item.course_average || 0
      }),
      backgroundColor: COLORS.course,
      borderRadius: 6
    })

    const labels = items.map((item) => item.name)
    const chart = new Chart(canvasRef.current.getContext("2d"), {
      type: "bar",
      data: {
        labels,
        datasets
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { position: "top" },
          tooltip: {
            callbacks: {
              label(context) {
                const label = context.dataset.label
                const value = context.raw
                return `${label}: ${formatMetricValue(value, metricUnit, percentMode ? 1 : 2)}`
              }
            }
          }
        },
        scales: {
          x: {
            ticks: {
              maxRotation: 45,
              minRotation: 0
            }
          },
          y: {
            beginAtZero: true,
            suggestedMax: percentMode ? 100 : 5,
            ticks: {
              callback(value) {
                return percentMode ? `${Number(value).toFixed(0)}%` : Number(value).toFixed(1)
              }
            }
          }
        }
      }
    })

    return () => chart.destroy()
  }, [ items, yAxisMode ])

  if (!Array.isArray(items) || items.length === 0) {
    return h("p", { className: "c-analytics-placeholder" }, "No competency data available for the selected filters.")
  }

  return h("div", { className: "c-analytics-chart", role: "img", "aria-label": "Average score by competency", style: { minHeight: "360px" } },
    h("canvas", { ref: canvasRef })
  )
}

const DomainAverageChart = ({ items, yAxisMode }) => {
  const canvasRef = useRef(null)

  useEffect(() => {
    if (!canvasRef.current || !Array.isArray(items) || items.length === 0) return undefined

    const percentMode = yAxisMode === "percent"
    const metricUnit = percentMode ? "percent" : "score"
    const datasets = [
      {
        label: percentMode ? "Student %" : "Student Avg",
        data: items.map((item) => {
          if (percentMode) return safeNumber(item.student_target_percent) ?? 0
          return item.student_average || 0
        }),
        backgroundColor: COLORS.student,
        borderRadius: 6
      },
      {
        label: percentMode ? "Advisor %" : "Advisor Avg",
        data: items.map((item) => {
          if (percentMode) return safeNumber(item.advisor_target_percent) ?? 0
          return item.advisor_average || 0
        }),
        backgroundColor: COLORS.advisor,
        borderRadius: 6
      }
    ]

    datasets.push({
      label: percentMode ? "Course %" : "Course Avg",
      data: items.map((item) => {
        if (percentMode) return safeNumber(item.course_target_percent) ?? 0
        return item.course_average || 0
      }),
      backgroundColor: COLORS.course,
      borderRadius: 6
    })

    const labels = items.map((item) => item.name)
    const chart = new Chart(canvasRef.current.getContext("2d"), {
      type: "bar",
      data: {
        labels,
        datasets
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { position: "top" },
          tooltip: {
            callbacks: {
              label(context) {
                const label = context.dataset.label
                const value = context.raw
                return `${label}: ${formatMetricValue(value, metricUnit, percentMode ? 1 : 2)}`
              }
            }
          }
        },
        scales: {
          x: {
            ticks: {
              maxRotation: 45,
              minRotation: 0
            }
          },
          y: {
            beginAtZero: true,
            suggestedMax: percentMode ? 100 : 5,
            ticks: {
              callback(value) {
                return percentMode ? `${Number(value).toFixed(0)}%` : Number(value).toFixed(1)
              }
            }
          }
        }
      }
    })

    return () => chart.destroy()
  }, [ items, yAxisMode ])

  if (!Array.isArray(items) || items.length === 0) {
    return h("p", { className: "c-analytics-placeholder" }, "No competency data available for the selected filters.")
  }

  return h("div", { className: "c-analytics-chart", role: "img", "aria-label": "Average score by domain", style: { minHeight: "360px" } },
    h("canvas", { ref: canvasRef })
  )
}

const CompetencyDetailChart = ({ data, selectedDomain, onDomainChange, sort, onSortChange }) => {
  const canvasRef = useRef(null)

  useEffect(() => {
    if (!canvasRef.current || !Array.isArray(data?.items) || data.items.length === 0) return undefined

    const chart = new Chart(canvasRef.current.getContext("2d"), {
      type: "bar",
      data: {
        labels: data.items.map((entry) => entry.name),
        datasets: [
          {
            label: "Student Avg",
            data: data.items.map((entry) => entry.student_average),
            backgroundColor: COLORS.student,
            borderRadius: 6
          },
          {
            label: "Advisor Avg",
            data: data.items.map((entry) => entry.advisor_average),
            backgroundColor: COLORS.advisor,
            borderRadius: 6
          },
          {
            label: "Course Avg",
            data: data.items.map((entry) => entry.course_average),
            backgroundColor: COLORS.course,
            borderRadius: 6
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { position: "top" },
          tooltip: {
            callbacks: {
              label(context) {
                const value = context.raw
                return `${context.dataset.label}: ${formatMetricValue(value, "score", 2)}`
              }
            }
          }
        },
        scales: {
          y: {
            suggestedMin: 0,
            suggestedMax: 5,
            ticks: {
              callback(value) {
                return Number(value).toFixed(1)
              }
            }
          },
          x: {
            ticks: {
              maxRotation: 45,
              minRotation: 0
            }
          }
        }
      }
    })

    return () => chart.destroy()
  }, [ data ])

  const domainOptions = Array.isArray(data?.domains) ? data.domains : []

  return h("div", { className: "space-y-4" }, [
    h("div", { className: "flex flex-wrap gap-3" }, [
      h("label", { className: "c-analytics-field" }, [
        h("span", null, "Domain"),
        h("select", {
          value: selectedDomain,
          onChange: (event) => onDomainChange(event.target.value)
        }, [
          h("option", { key: "domain-all", value: "all" }, "All domains"),
          ...domainOptions.map((domain) => h("option", { key: `domain-${domain.id}`, value: String(domain.id) }, domain.name))
        ])
      ]),
      h("label", { className: "c-analytics-field" }, [
        h("span", null, "Sort by"),
        h("select", {
          value: sort,
          onChange: (event) => onSortChange(event.target.value)
        }, [
          h("option", { key: "sort-student", value: "student" }, "Student avg"),
          h("option", { key: "sort-advisor", value: "advisor" }, "Advisor avg"),
          h("option", { key: "sort-gap", value: "gap" }, "Largest gap"),
          h("option", { key: "sort-name", value: "name" }, "Name")
        ])
      ])
    ]),
    Array.isArray(data?.items) && data.items.length > 0
      ? h("div", { className: "c-analytics-chart", style: { minHeight: "360px" } }, h("canvas", { ref: canvasRef }))
      : h("p", { className: "c-analytics-placeholder" }, "No competency data available for the selected filters.")
  ])
}

const TrackAchievementChart = ({ tracks }) => {
  const canvasRef = useRef(null)

  useEffect(() => {
    if (!canvasRef.current || !Array.isArray(tracks) || tracks.length === 0) return undefined

    const labels = tracks.map((track) => track.track || track.title)
    const achievedPercents = tracks.map((track) => safeNumber(track.achieved_percent) ?? 0)
    const notMetPercents = tracks.map((track) => safeNumber(track.not_met_percent) ?? 0)
    const notAssessedPercents = tracks.map((track) => safeNumber(track.not_assessed_percent) ?? 0)

    const chart = new Chart(canvasRef.current.getContext("2d"), {
      type: "bar",
      data: {
        labels,
        datasets: [
          {
            label: "Achieved",
            data: achievedPercents,
            backgroundColor: COLORS.achieved,
            borderRadius: 10,
            stack: "status",
            showDataLabels: true
          },
          {
            label: "Not met",
            data: notMetPercents,
            backgroundColor: COLORS.notMet,
            borderRadius: 10,
            stack: "status"
          },
          {
            label: "Not assessed",
            data: notAssessedPercents,
            backgroundColor: COLORS.notAssessed,
            borderRadius: 10,
            stack: "status"
          }
        ]
      },
      options: {
        indexAxis: "y",
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: false },
          tooltip: {
            callbacks: {
              title(context) {
                const trackEntry = tracks[context[0].dataIndex]
                if (!trackEntry) return null
                const primary = trackEntry.track || trackEntry.title
                const secondary = compact([ trackEntry.title, trackEntry.semester ]).join(" · ")
                return primary || secondary || "Track"
              },
              label(context) {
                const trackEntry = tracks[context.dataIndex]
                const label = context.dataset.label
                const percent = safeNumber(context.raw) ?? 0
                let count = 0
                if (label === "Achieved") count = trackEntry?.achieved_count ?? 0
                if (label === "Not met") count = trackEntry?.not_met_count ?? 0
                if (label === "Not assessed") count = trackEntry?.not_assessed_count ?? 0
                return `${label}: ${percent.toFixed(1)}% (${count})`
              }
            }
          },
          percentageLabelPlugin: {
            color: COLORS.neutralText
          }
        },
        scales: {
          x: {
            stacked: true,
            min: 0,
            max: 100,
            ticks: {
              callback(value) {
                return `${value}%`
              }
            }
          },
          y: {
            stacked: true,
            ticks: {
              autoSkip: false
            }
          }
        }
      }
    })

    return () => chart.destroy()
  }, [ tracks ])

  if (!Array.isArray(tracks) || tracks.length === 0) {
    return h("p", { className: "c-analytics-placeholder" }, "No track performance data available.")
  }

  return h("div", { className: "c-analytics-chart", role: "img", "aria-label": "Percent achieved by track", style: { minHeight: "360px" } },
    h("canvas", { ref: canvasRef })
  )
}

// ─── Employment charts ───────────────────────────────────────────────────────

const EmploymentStatusChart = ({ statusCounts }) => {
  const canvasRef = useRef(null)

  useEffect(() => {
    if (!canvasRef.current || !Array.isArray(statusCounts) || statusCounts.length === 0) return undefined
    const labels = statusCounts.map((s) => s.label)
    const data   = statusCounts.map((s) => s.count)
    const colors = statusCounts.map((s) => {
      if (s.label === "Employed")      return COLORS.achieved
      if (s.label === "Not employed")  return COLORS.notMet
      return COLORS.notAssessed
    })

    const chart = new Chart(canvasRef.current.getContext("2d"), {
      type: "doughnut",
      data: { labels, datasets: [{ data, backgroundColor: colors, borderWidth: 2 }] },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { position: "right" },
          tooltip: {
            callbacks: {
              label(context) {
                const total = data.reduce((a, b) => a + b, 0)
                const pct   = total > 0 ? ((context.raw / total) * 100).toFixed(1) : "0.0"
                return `${context.label}: ${context.raw} (${pct}%)`
              }
            }
          }
        }
      }
    })
    return () => chart.destroy()
  }, [ statusCounts ])

  if (!Array.isArray(statusCounts) || statusCounts.length === 0) {
    return h("p", { className: "c-analytics-placeholder" }, "No employment status data available.")
  }
  return h("div", { className: "c-analytics-chart", role: "img", "aria-label": "Employment status breakdown", style: { minHeight: "280px" } },
    h("canvas", { ref: canvasRef })
  )
}

const EmploymentHoursChart = ({ distribution }) => {
  const canvasRef = useRef(null)

  useEffect(() => {
    if (!canvasRef.current || !distribution) return undefined
    const chart = new Chart(canvasRef.current.getContext("2d"), {
      type: "bar",
      data: {
        labels: distribution.labels,
        datasets: [{
          label: "Students",
          data: distribution.data,
          backgroundColor: COLORS.student,
          borderRadius: 6
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { display: false } },
        scales: {
          y: { beginAtZero: true, ticks: { stepSize: 1, precision: 0 } }
        }
      }
    })
    return () => chart.destroy()
  }, [ distribution ])

  if (!distribution) return h("p", { className: "c-analytics-placeholder" }, "No hours data available.")
  return h("div", { className: "c-analytics-chart", role: "img", "aria-label": "Hours per week distribution", style: { minHeight: "260px" } },
    h("canvas", { ref: canvasRef })
  )
}

const EmploymentFlexibilityChart = ({ distribution }) => {
  const canvasRef = useRef(null)

  useEffect(() => {
    if (!canvasRef.current || !distribution) return undefined
    const chart = new Chart(canvasRef.current.getContext("2d"), {
      type: "bar",
      data: {
        labels: distribution.labels,
        datasets: [{
          label: "Students",
          data: distribution.data,
          backgroundColor: COLORS.advisor,
          borderRadius: 6
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { display: false } },
        scales: {
          x: { ticks: { maxRotation: 30, minRotation: 0 } },
          y: { beginAtZero: true, ticks: { stepSize: 1, precision: 0 } }
        }
      }
    })
    return () => chart.destroy()
  }, [ distribution ])

  if (!distribution) return h("p", { className: "c-analytics-placeholder" }, "No flexibility data available.")
  return h("div", { className: "c-analytics-chart", role: "img", "aria-label": "Work schedule flexibility distribution", style: { minHeight: "260px" } },
    h("canvas", { ref: canvasRef })
  )
}

const EmploymentTab = ({ data, onExport }) => {
  if (!data) return h("p", { className: "c-analytics-placeholder" }, "Loading employment data…")

  const { total_respondents, employment_rate, status_counts, hours_distribution, flexibility_distribution } = data

  return h("div", { className: "space-y-8" }, [
    // Summary banner
    h("div", { className: "flex flex-wrap gap-4" }, [
      h("div", { className: "rounded-lg border border-slate-200 bg-white px-5 py-3 shadow-sm" }, [
        h("p", { className: "text-xs font-semibold uppercase tracking-wide text-slate-500" }, "Total respondents"),
        h("p", { className: "text-2xl font-bold text-slate-900" }, String(total_respondents ?? "—"))
      ]),
      employment_rate !== null && employment_rate !== undefined
        ? h("div", { className: "rounded-lg border border-slate-200 bg-white px-5 py-3 shadow-sm" }, [
            h("p", { className: "text-xs font-semibold uppercase tracking-wide text-slate-500" }, "Employment rate"),
            h("p", { className: "text-2xl font-bold text-slate-900" }, `${employment_rate}%`)
          ])
        : null
    ].filter(Boolean)),

    // Status donut
    h("div", { className: "space-y-2" }, [
      h("h3", { className: "text-sm font-semibold text-slate-700" }, "Employment Status"),
      h(EmploymentStatusChart, { statusCounts: status_counts })
    ]),

    // Hours + Flexibility side by side on wide screens
    h("div", { className: "grid gap-6 md:grid-cols-2" }, [
      h("div", { className: "space-y-2" }, [
        h("h3", { className: "text-sm font-semibold text-slate-700" }, "Hours per Week"),
        h(EmploymentHoursChart, { distribution: hours_distribution })
      ]),
      h("div", { className: "space-y-2" }, [
        h("h3", { className: "text-sm font-semibold text-slate-700" }, "Work Schedule Flexibility"),
        h(EmploymentFlexibilityChart, { distribution: flexibility_distribution })
      ])
    ])
  ])
}

const VIEW_TOGGLE_BASE = "inline-flex items-center rounded-md border px-3 py-1.5 text-xs font-medium transition focus:outline-none focus:ring-2 focus:ring-amber-500 focus:ring-offset-2"

const YAxisToggle = ({ mode, onChange }) => {
  const scoreActive = mode !== "percent"
  const percentActive = mode === "percent"
  const buttonClass = (active) => `${VIEW_TOGGLE_BASE} ${active ? "border-amber-500 bg-amber-100 text-amber-900" : "border-slate-300 bg-white text-slate-600 hover:bg-slate-50"}`

  return h("div", { className: "flex flex-wrap items-center gap-2" }, [
    h("span", { className: "text-xs font-medium text-slate-600" }, "Y-axis:"),
    h("button", {
      type: "button",
      className: buttonClass(scoreActive),
      onClick: () => onChange("score"),
      "aria-pressed": scoreActive
    }, "Average score"),
    h("button", {
      type: "button",
      className: buttonClass(percentActive),
      onClick: () => onChange("percent"),
      "aria-pressed": percentActive
    }, "% meeting target")
  ])
}

const TabNavigation = ({ tabs, activeKey, onChange }) => {
  if (!Array.isArray(tabs) || tabs.length === 0) return null

  return h("div", { className: "c-tabs", role: "tablist" },
    tabs.map((tab) => {
      const isActive = tab.key === activeKey
      const className = `c-tab${isActive ? " is-active" : ""}`
      return h("button", {
        key: tab.key,
        type: "button",
        className,
        role: "tab",
        "aria-selected": isActive,
        onClick: () => onChange(tab.key)
      }, tab.label)
    })
  )
}

const StatusLegend = ({ statuses = [ "exceeds", "achieved", "not_met", "not_assessed" ] }) => {
  const entries = statuses
    .map((status) => ({
      key: status,
      label: STATUS_LABELS[status],
      color: STATUS_COLOR_MAP[status] || ratingColor(status)
    }))
    .filter((entry) => entry.label && entry.color)

  if (entries.length === 0) return null

  return h("div", { className: "flex flex-wrap gap-4 text-xs text-slate-600" },
    entries.map((entry) => h("span", { key: entry.key, className: "inline-flex items-center gap-2" }, [
      h("span", { className: "h-3 w-3 rounded-full", style: { backgroundColor: entry.color } }),
      entry.label
    ]))
  )
}

const ReportsApp = ({ initialFilters = {} }) => {
  const initialDashboardFilters = useMemo(() => normalizeDashboardFilters(initialFilters), [ initialFilters ])
  const [ options, setOptions ] = useState(EMPTY_OPTIONS)
  const [ filters, setFilters ] = useState(initialDashboardFilters)
  const [ benchmark, setBenchmark ] = useState(null)
  const [ competencies, setCompetencies ] = useState([])
  const [ tracks, setTracks ] = useState([])
  const [ competencyDetail, setCompetencyDetail ] = useState(null)
  const [ loading, setLoading ] = useState(true)
  const [ error, setError ] = useState(null)
  const [ activeTab, setActiveTab ] = useState("competency")
  const [ yAxisMode, setYAxisMode ] = useState("percent")
  const [ competencyDetailDomain, setCompetencyDetailDomain ] = useState("all")
  const [ competencyDetailSort, setCompetencyDetailSort ] = useState("student")
  const [ employment, setEmployment ] = useState(null)
  const filtersRef = useRef(initialDashboardFilters)

  const filtersDescription = useMemo(() => describeActiveFilters(filters, options), [ filters, options ])

  const loadData = useCallback(async (nextFilters) => {
    try {
      setLoading(true)
      setError(null)
      const inputFilters = (nextFilters && typeof nextFilters === "object") ? nextFilters : filtersRef.current
      const resolvedFilters = { ...DEFAULT_FILTERS, ...inputFilters }
      const query = buildQueryString(resolvedFilters)
      const [ benchmarkRes, competencyRes, trackRes, competencyDetailRes, employmentRes ] = await Promise.all([
        fetchJson(`${API_ENDPOINTS.benchmark}${query}`),
        fetchJson(`${API_ENDPOINTS.competency}${query}`),
        fetchJson(`${API_ENDPOINTS.track}${query}`),
        fetchJson(`${API_ENDPOINTS.competencyDetail}${query}`),
        fetchJson(`${API_ENDPOINTS.employment}${query}`)
      ])

      filtersRef.current = resolvedFilters
      setFilters(resolvedFilters)
      setBenchmark(benchmarkRes)
      setCompetencies(Array.isArray(competencyRes) ? competencyRes : [])
      setTracks(Array.isArray(trackRes) ? trackRes : [])
      setCompetencyDetail(competencyDetailRes)
      setEmployment(employmentRes)
    } catch (err) {
      console.error(err)
      setError(err.message || "We could not load the report data.")
    } finally {
      setLoading(false)
    }
  }, [])

  const loadFilters = useCallback(async () => {
    try {
      setLoading(true)
      setError(null)
      const data = await fetchJson(API_ENDPOINTS.filters)
      const preparedOptions = {
        tracks: Array.isArray(data.tracks) ? data.tracks : [],
        program_years: Array.isArray(data.program_years) ? data.program_years : [],
        semesters: Array.isArray(data.semesters) ? data.semesters : [],
        advisors: Array.isArray(data.advisors) ? data.advisors : [],
        categories: Array.isArray(data.categories) ? data.categories : [],
        surveys: Array.isArray(data.surveys) ? data.surveys : [],
        students: Array.isArray(data.students) ? data.students : [],
        competencies: Array.isArray(data.competencies) ? data.competencies : []
      }
      setOptions(preparedOptions)
      await loadData(initialDashboardFilters)
    } catch (err) {
      console.error(err)
      setOptions(EMPTY_OPTIONS)
      setError(err.message || "We could not load the report filters.")
      setLoading(false)
    }
  }, [ initialDashboardFilters, loadData ])

  const handleFilterChange = useCallback((nextFilters) => {
    const merged = { ...DEFAULT_FILTERS, ...(nextFilters || {}) }
    loadData(merged)
  }, [ loadData ])

  const handleReset = useCallback(() => {
    loadData(DEFAULT_FILTERS)
  }, [ loadData ])

  useEffect(() => {
    loadFilters()
  }, [ loadFilters ])

  useEffect(() => {
    updatePrimaryDashboardDownload(filters)
    syncDashboardUrl(filters)
  }, [ filters ])

  useEffect(() => {
    const domainIds = new Set((competencyDetail?.domains || []).map((domain) => String(domain.id)))
    if (competencyDetailDomain !== "all" && !domainIds.has(String(competencyDetailDomain))) {
      setCompetencyDetailDomain("all")
    }
  }, [ competencyDetail, competencyDetailDomain ])

  const competencyAchievementItems = useMemo(() => {
    if (!Array.isArray(competencyDetail?.items)) return []

    return competencyDetail.items.map((item) => {
      const achieved = Number(item?.achieved_count)
      const notMet = Number(item?.not_met_count)
      const notAssessed = Number(item?.not_assessed_count)

      return {
        ...item,
        achieved_count: Number.isFinite(achieved) ? achieved : 0,
        not_met_count: Number.isFinite(notMet) ? notMet : 0,
        not_assessed_count: Number.isFinite(notAssessed) ? notAssessed : 0
      }
    })
  }, [ competencyDetail ])

  const summaryCards = Array.isArray(benchmark?.cards) ? benchmark.cards : []
  const timeline = Array.isArray(benchmark?.timeline) ? benchmark.timeline : []


  const chartTabs = useMemo(() => {
    const tabs = []

    tabs.push({
      key: "competency",
      label: "Competency",
      title: "Num Achieved by Competency",
      description: "Side-by-side comparison of student self-ratings, advisor ratings, and course-derived ratings averaged per competency.",
      axisToggle: h(YAxisToggle, { mode: yAxisMode, onChange: setYAxisMode }),
      content: h(CompetencyAchievementChart, { items: competencyAchievementItems, yAxisMode }),
      footnote: h("p", { className: "text-xs text-slate-500 space-y-1" }, [
        "Averages are calculated based on all responses within each competency.",
        filtersDescription && filtersDescription !== "None" ? h("span", { className: "block" }, `Filters applied: ${filtersDescription}`) : null
      ].filter(Boolean))
    })

    tabs.push({
      key: "domain",
      label: "Domain",
      title: "Num Achieved by Domain",
      description: "Side-by-side comparison of student self-ratings, advisor ratings, and course-derived ratings averaged per domain.",
      axisToggle: h(YAxisToggle, { mode: yAxisMode, onChange: setYAxisMode }),
      content: h(DomainAverageChart, { items: competencies, yAxisMode }),
      footnote: h("p", { className: "text-xs text-slate-500 space-y-1" }, [
        "Averages are calculated based on all responses within each domain.",
        filtersDescription && filtersDescription !== "None" ? h("span", { className: "block" }, `Filters applied: ${filtersDescription}`) : null
      ].filter(Boolean))
    })

    tabs.push({
      key: "track",
      label: "Track",
      title: "% All Competency Achieved by Track",
      description: "Horizontal stacked bars highlight attainment percentages alongside missing and unassessed counts.",
      content: h(React.Fragment, null, [
        h(StatusLegend, { statuses: [ "achieved", "not_met", "not_assessed" ] }),
        h(TrackAchievementChart, { tracks })
      ]),
      footnote: (filtersDescription && filtersDescription !== "None")
        ? h("p", { className: "text-xs text-slate-500" }, `Filters applied: ${filtersDescription}`)
        : null
    })

    tabs.push({
      key: "trend",
      label: "Trend",
      title: "Progress Over Time",
      description: "Monthly average scores for students, advisors, and course ratings so you can spot improvements or regression at a glance.",
      axisToggle: h(YAxisToggle, { mode: yAxisMode, onChange: setYAxisMode }),
      content: timeline.length > 0
        ? h(TrendChart, { timeline, yAxisMode })
        : h("p", { className: "c-analytics-placeholder" }, "No trend data available."),
      footnote: h("p", { className: "text-xs text-slate-500" }, `Filters applied: ${filtersDescription}`)
    })

    tabs.push({
      key: "employment",
      label: "Employment",
      title: "Employment Across Respondents",
      description: "Employment status, hours worked per week, and schedule flexibility across all respondents in the current filter selection.",
      content: h(EmploymentTab, { data: employment }),
      footnote: (filtersDescription && filtersDescription !== "None")
        ? h("p", { className: "text-xs text-slate-500" }, `Filters applied: ${filtersDescription}`)
        : null
    })

    return tabs
  }, [ competencies, competencyAchievementItems, employment, filtersDescription, timeline, tracks, yAxisMode ])

  useEffect(() => {
    if (!Array.isArray(chartTabs) || chartTabs.length === 0) return
    if (!chartTabs.some((tab) => tab.key === activeTab)) {
      setActiveTab(chartTabs[0].key)
    }
  }, [ chartTabs, activeTab ])

  const activeTabConfig = chartTabs.find((tab) => tab.key === activeTab) || chartTabs[0] || null

  if (loading) {
    return h(LoadingState)
  }

  if (error) {
    return h(ErrorState, { message: error, onRetry: loadFilters })
  }

  if (!benchmark) {
    return h(ErrorState, { message: "No analytics are available for the selected filters.", onRetry: loadFilters })
  }

  return h("div", { className: "c-analytics-layout space-y-8" }, [
    h(FilterBar, { filters, options, onChange: handleFilterChange, onReset: handleReset }),
    summaryCards.length > 0 ? h(SummaryCards, { cards: summaryCards }) : null,
    h("section", { className: "c-analytics-panel space-y-5" }, [
      h("div", { className: "space-y-1" }, [
        h("h2", null, "Analytics Visualizations"),
        h("p", null, "Use the tabs below to switch between the available charts.")
      ]),
      h("div", { className: "c-tabs-wrap space-y-4" }, [
        h(TabNavigation, { tabs: chartTabs, activeKey: activeTab, onChange: setActiveTab }),
        activeTabConfig
          ? h("div", { className: "c-tab-panel space-y-4" }, [
              h("header", { className: "c-analytics-panel__header flex flex-wrap items-start justify-between gap-4" }, [
                h("div", { className: "space-y-2" }, [
                  h("div", { className: "space-y-1" }, [
                    h("h2", null, activeTabConfig.title),
                    h("p", null, activeTabConfig.description)
                  ]),
                  activeTabConfig.axisToggle
                ].filter(Boolean))
              ]),
              activeTabConfig.content,
              activeTabConfig.footnote
            ].filter(Boolean))
          : h("p", { className: "c-analytics-placeholder" }, "No charts available.")
      ])
    ])
  ].filter(Boolean))
}

export default ReportsApp
