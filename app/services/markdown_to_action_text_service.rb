# frozen_string_literal: true

class MarkdownToActionTextService
  def self.convert(markdown_text)
    new(markdown_text).to_action_text
  end

  def initialize(markdown_text)
    @markdown_text = markdown_text
  end

  def to_action_text
    return nil if @markdown_text.blank?

    html = convert_markdown_to_html
    ActionText::Content.new(html)
  end

  private

  def convert_markdown_to_html
    renderer = Redcarpet::Render::HTML.new(
      hard_wrap: true,
      link_attributes: { target: '_blank', rel: 'noopener' },
      no_intra_emphasis: true,
      fenced_code_blocks: true,
      autolink: true,
      tables: true,
      strikethrough: true,
      space_after_headers: true
    )

    markdown = Redcarpet::Markdown.new(renderer,
                                       autolink: true,
                                       tables: true,
                                       fenced_code_blocks: true,
                                       strikethrough: true,
                                       superscript: true,
                                       underline: true,
                                       no_intra_emphasis: true,
                                       space_after_headers: true)

    # Convert markdown to HTML and let ActionText handle sanitization
    markdown.render(@markdown_text)
  end
end
