import { Application } from "@hotwired/stimulus"

const application = Application.start()

// Configure Stimulus development experience
application.debug = false
window.Stimulus   = application

export { application }

// Simple handler to convert <a data-method="delete"> or data-turbo-method into a form POST with _method override.
// This is a tiny replacement for rails-ujs's data-method handling when that library isn't loaded.
document.addEventListener("click", async (event) => {
	const el = event.target.closest && event.target.closest('a')
	if (!el) return
	if (event.defaultPrevented) return

	// Support both rails-ujs style `data-method` and Turbo `data-turbo-method`
	const rawMethod = el.getAttribute('data-method') || el.getAttribute('data-turbo-method')
	const method = (rawMethod || '').toUpperCase()
	if (!method || method === 'GET') return

	event.preventDefault()

	const message = el.getAttribute('data-turbo-confirm') || el.getAttribute('data-confirm')
	if (message) {
		const confirmed = window.AppModal && typeof window.AppModal.confirm === 'function'
			? await window.AppModal.confirm({ message: message, title: 'Confirm action' })
			: window.confirm(message)

		if (!confirmed) return
	}

	const form = document.createElement('form')
	form.method = 'post'
	form.action = el.href
	form.style.display = 'none'

	// Add method override
	const methodInput = document.createElement('input')
	methodInput.type = 'hidden'
	methodInput.name = '_method'
	methodInput.value = method
	form.appendChild(methodInput)

	// Add authenticity token if present
	const csrfParam = document.querySelector('meta[name=csrf-param]')
	const csrfToken = document.querySelector('meta[name=csrf-token]')
	if (csrfToken) {
		const tokenInput = document.createElement('input')
		tokenInput.type = 'hidden'
		tokenInput.name = (csrfParam && csrfParam.getAttribute('content')) || 'authenticity_token'
		tokenInput.value = csrfToken.getAttribute('content')
		form.appendChild(tokenInput)
	}

	document.body.appendChild(form)
	form.submit()
})
