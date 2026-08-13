Rails.application.routes.draw do
  devise_for :users, path: "", controllers: {
    sessions: "sessions",
    omniauth_callbacks: "omniauth_callbacks"
  }, path_names: {
    sign_in: "sign_in",
    sign_out: "sign_out"
  }

  devise_scope :user do
    # Primary landing page shows the admin sign-in screen
    root to: "sessions#new"

    get "sign_in", to: "sessions#new", as: :new_user_session
    post "sign_in", to: "sessions#create", as: :user_session
    delete "sign_out", to: "sessions#destroy", as: :destroy_user_session

    # Accept GET requests to /sign_out safely by redirecting to root
    # This avoids GET requests (from bots or cached links) being treated as
    # Admin resource IDs (e.g. /sign_out -> AdminsController#show with id="sign_out").
    # Devise expects DELETE for sign_out; this GET handler is a harmless redirect.
    get "sign_out", to: "sessions#sign_out_get_fallback"
  end

  # Authenticated dashboard entry point
  get "dashboard", to: "dashboards#show", as: :dashboard

  # Role-specific dashboard routes
  get "student_dashboard", to: "dashboards#student", as: :student_dashboard
  get "advisor_dashboard", to: "dashboards#advisor", as: :advisor_dashboard
  get "admin_dashboard", to: "dashboards#admin", as: :admin_dashboard
  post "switch_role", to: "dashboards#switch_role", as: :switch_role

  get "survey_records", to: "student_records#index", as: :survey_records
  get "survey_records/export_excel", to: "student_records#export_excel", as: :export_survey_records_excel
  get "student_records", to: redirect { |_params, request|
    query = request.query_string.present? ? "?#{request.query_string}" : ""
    "/survey_records#{query}"
  }, as: :student_records
  get "student_records/export_excel", to: redirect { |_params, request|
    query = request.query_string.present? ? "?#{request.query_string}" : ""
    "/survey_records/export_excel#{query}"
  }, as: :export_student_records_excel
  resources :student_overviews, only: %i[index show] do
    get :export_excel, on: :collection
    get :competency_history, on: :member
  end
  resource :student_competencies, only: :show
  get "student_portfolio_export", to: "student_portfolio_exports#index", as: :student_portfolio_export
  get "student_portfolio_export/download", to: "student_portfolio_exports#show", as: :download_student_portfolio_export

  get "manage_students", to: "dashboards#manage_students", as: :manage_students
  patch "manage_students", to: "dashboards#update_student_advisors", as: :update_student_advisors
  get "people_management", to: "dashboards#people_management", as: :people_management

  # Reporting hub shared by admins and advisors
  get "reports", to: "reports#show", as: :reports
  get "reports/export_excel", to: "reports#export_excel", as: :export_reports_excel
  get "reports/export_tab", to: "reports#export_tab_csv", as: :export_report_tab
  get "reports/profile_export.xlsx", to: "reports#export_portfolio", as: :export_reports_portfolio
  get "reports/course_competencies.csv", to: "reports#export_course_competencies", as: :export_course_competency_reports
  get "reports/:section/export_pdf", to: "reports#export_pdf", as: :export_reports_pdf

  # Competency matrix shared by admins and advisors. The admin-prefixed route
  # remains available for admins and older bookmarks, but advisors use this
  # neutral path so the page does not look admin-only.
  resources :competencies, controller: "admin/competencies", only: %i[index show] do
    collection do
      get :export
    end
  end

  # Admin-specific management routes
  get "manage_members", to: "dashboards#manage_members", as: :manage_members
  patch "update_roles", to: "dashboards#update_roles", as: :update_roles
  delete "manage_members", to: "dashboards#destroy_members", as: :remove_members
  delete "manage_members/:id", to: "dashboards#destroy_member", as: :remove_member
  get "debug_users", to: "dashboards#debug_users", as: :debug_users

  # Admin-only: start impersonating a student; while impersonating, allow exit.
  resource :impersonation, only: %i[new create destroy]

  # Admin-only: start impersonating an advisor; while impersonating, allow exit.
  resource :advisor_impersonation, only: %i[new create destroy]

  namespace :admin do
    resource :maintenance, only: %i[show update] do
      post :normalize_target_levels
    end
    get "program_setup", to: "program_setups#show", as: :program_setup
    resources :competencies, only: %i[index show] do
      collection do
        get :export
        patch :course_rule
      end
    end
    get "target_levels", to: "target_levels#index", as: :target_levels
    patch "target_levels", to: "target_levels#update"
    post "target_levels/fill_defaults", to: "target_levels#fill_defaults", as: :fill_default_target_levels
    post "target_levels/copy_to_current", to: "target_levels#copy_to_current", as: :copy_target_levels_to_current
    resources :course_competency_targets, only: %i[create update destroy]
    post "course_competency_targets/import_matrix", to: "course_competency_targets#import_matrix", as: :import_course_competency_target_matrix
    resources :course_grade_release_dates, only: %i[index new create edit update destroy] do
      collection do
        patch :bulk_update
      end
    end
    resources :grade_import_batches, only: %i[index new create show destroy] do
      collection do
        get "samples/:kind", to: "grade_import_batches#sample", as: :sample
      end
      member do
        post :approve
        post :commit
        post :reupload
        post :rollback
        post :recommit
        post :rebuild_ratings
        post :finalize
        patch :semester
        patch :course_code, to: "grade_import_batches#update_course_code"
        get :export_ratings
        get :export_evidence
        get :error_report
        get :correction_file
        patch :pending_row_group, to: "grade_import_batches#update_pending_row_group"
        patch "pending_rows/:pending_row_id", to: "grade_import_batches#update_pending_row", as: :pending_row
        patch "evidence/:evidence_id", to: "grade_import_batches#update_evidence", as: :evidence
      end
    end
    resources :program_tracks, only: %i[create update destroy] do
      collection do
        patch :reorder
      end
    end
    resources :majors, only: %i[create update destroy]
    resources :program_years, only: %i[create update destroy] do
      collection do
        patch :reorder
      end
    end
    resources :surveys do
      member do
        get :preview
        get :copy
        post :copy_to_semester
        patch :archive
        patch :activate
      end
    end
    resources :questions
    resources :activities, only: :index
    resources :survey_change_logs, only: :index
    resources :program_semesters, only: %i[create update destroy] do
      member do
        patch :make_current
      end
    end
  end

  resources :categories
  resources :feedbacks
  resources :questions
  resources :question_responses

  resources :students, only: %i[index update]
  patch "students/:id/update_advisor", to: "dashboards#update_student_advisor", as: :update_student_advisor

  # Account settings (all roles share this page)
  resource :account, only: %i[show edit update]

  resources :surveys do
    post :submit, on: :member
    post :save_progress, on: :member
  end

  # Accept GET requests to /surveys/:id/submit and redirect to the survey show page.
  # This avoids a noisy RoutingError if a user or external crawler follows a cached/old GET link.
  get 'surveys/:id/submit', to: redirect('/surveys/%{id}')

  resources :notifications, only: %i[index show update] do
    collection do
      patch :mark_all_read
    end
  end

  get "survey_responses", to: redirect { |_params, request|
    query = request.query_string.present? ? "?#{request.query_string}" : ""
    "/survey_records#{query}"
  }

  resources :survey_responses, only: :show do
    member do
      get :download
      get :composite_report
      get :edit
      patch :update
      patch :confidential_advisor_note, to: "confidential_advisor_notes#update"
      delete :destroy
    end
  end

  # Survey assignment hub shared by advisors and admins.
  namespace :assignments do
    resources :surveys, only: %i[index show] do
      post   :assign,     on: :member
      post   :assign_all, on: :member
      delete :unassign,   on: :member
      delete :unassign_selected, on: :member
      patch  :availability, on: :member
      patch  :extend_deadline, on: :member
      patch  :extend_group_deadline, on: :member
      patch  :reopen, on: :member
    end
  end

  # Evidence helpers
  get "evidence/check_access", to: "evidence#check_access", as: :evidence_check_access, defaults: { format: :json }

  namespace :advisors do
    # Kept for backwards-compatible bookmarks.
    get "surveys", to: redirect("/assignments/surveys")
    get "surveys/:id", to: redirect("/assignments/surveys/%{id}")
    resources :meeting_recaps, only: %i[index]
    resources :students, only: %i[show update] do
      resources :meeting_recaps, only: %i[new create edit update]
    end
  end

  namespace :api do
    post "markdown_preview", to: "markdown_previews#create", as: :markdown_preview
    get "reports/filters", to: "reports#filters"
    get "reports/competency-summary", to: "reports#competency_summary"
    get "reports/competency-detail", to: "reports#competency_detail"
    get "reports/track-summary", to: "reports#track_summary"
    get "reports/benchmark", to: "reports#benchmark"
    get "reports/employment-summary", to: "reports#employment_summary"
  end

  get "about", to: "pages#about", as: :about
  get "faq",   to: "pages#faq",   as: :faq

  get "maintenance", to: "pages#maintenance", as: :maintenance

  # User settings page (accessible to any authenticated user)
  get "settings", to: "settings#show", as: :settings
  get "settings/edit", to: "settings#edit", as: :edit_settings
  patch "settings", to: "settings#update"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
