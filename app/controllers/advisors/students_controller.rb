module Advisors
  class StudentsController < BaseController
    def index
      redirect_to survey_records_path
    end

    def show
      @student = Student.find(params[:id])
    end

    def update
      @student = Student.find(params[:id])

      incoming = params.dig(:student, :track).to_s.presence
      valid_keys = Student.tracks.keys # => ["residential", "executive"]

      unless incoming && valid_keys.include?(incoming)
        redirect_back fallback_location: survey_records_path,
                      alert: "We could not change the track because the student's current track is missing or cannot be determined."
        return
      end

      if @student.update(track: incoming)
        timestamp = begin
          I18n.l(Time.zone.now, format: :long)
        rescue I18n::MissingTranslationData
          Time.zone.now.to_fs(:long)
        end
        redirect_to advisors_student_path(@student),
                    notice: %(Track changed to "#{@student.track.titleize}" at #{timestamp}.)
      else
        redirect_back fallback_location: advisors_student_path(@student),
                      alert: @student.errors.full_messages.to_sentence
      end
    rescue ActiveRecord::RecordNotFound
      redirect_back fallback_location: survey_records_path,
                    alert: "Student not found."
    end

    private

    def student_params
      params.require(:student).permit(:track)
    end
  end
end
