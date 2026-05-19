# frozen_string_literal: true

module GuidanceTextHelper
  include MarkdownHelper

  def render_guidance_text(text, heading_tag: :h4, wrapper_class: "c-rich-text")
    level = heading_tag.to_s.sub(/\Ah/i, "").to_i
    min_heading_level = level.between?(1, 6) ? level : 4
    render_markdown(text, wrapper_class: wrapper_class, min_heading_level: min_heading_level)
  end
end
