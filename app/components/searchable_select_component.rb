# A simple searchable combobox backed by the global combobox JavaScript.
#
# The user types into the textbox, chooses from the filtered popup, and the
# component submits the selected option value through a hidden field.
#
# Usage:
#   render SearchableSelectComponent.new(
#     id: "student-user-id",
#     name: "impersonation[user_id]",
#     label: "Student",
#     placeholder: "Select a student...",
#     search_placeholder: "Search by name or email...",
#     options: [{ value: 1, label: "Jane", description: "jane@x.com" }]
#   )
class SearchableSelectComponent < ViewComponent::Base
  def initialize(id:, name:, label:, options:, placeholder: "", required: true)
    @id = id
    @name = name
    @label = label
    @options = options
    @placeholder = placeholder
    @required = required
  end

  private

  attr_reader :id, :name, :label, :placeholder, :required

  def normalized_options
    Array(@options).map do |opt|
      opt = opt.to_h.with_indifferent_access
      value = opt.fetch(:value)
      label_text = opt.fetch(:label)
      description = opt[:description]

      {
        value:,
        label: label_text,
        description:
      }
    end
  end
end
