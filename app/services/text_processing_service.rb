# frozen_string_literal: true

# app/services/text_processing_service.rb

class TextProcessingService
  attr_reader :text

  def initialize(text)
    @text = text
  end

  def clean_text
    text.gsub(/\n/, ' ').gsub(/\s+/, ' ').strip
  end

  def split_text_into_fragments(max_tokens: 500)
    cleaned_text = clean_text
    sentences = cleaned_text.scan(/[^.!?]+[.!?]/).map(&:strip)

    # If there is no period, the text is not split into
    # sentences either. In that case everything is a single sentence.

    sentences = [clean_text] if sentences == [] && clean_text.present?

    fragments = []
    current_fragment = ''
    sentences.each do |sentence|
      temp_fragment = "#{current_fragment} #{sentence}".strip
      if count_tokens(temp_fragment) <= max_tokens
        current_fragment = temp_fragment
      else
        fragments << current_fragment
        current_fragment = sentence
      end
    end
    fragments << current_fragment if current_fragment.present?
    fragments
  end

  private

  def count_tokens(text)
    (text.split.size / 0.75).ceil # 1 token ≈ 0.75 words
  end
end
