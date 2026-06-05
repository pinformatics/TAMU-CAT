# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :uin, :student_uin, :student_email, :student_name, :student_id, :advisor_id,
  :answers, :answer, :response_value, :raw_answers, :other_answers, :feedback, :comments,
  :evidence_link, :portfolio_url, :google_site_url,
  :raw_grade, :mapped_level, :course_target_level, :grade, :grades,
  :file_checksum, :import_fingerprint, :source_key
]
