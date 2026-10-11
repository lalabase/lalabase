# frozen_string_literal: true

require 'rails_helper'

# The ONE Markdown display path: safe render + prose typography + optional preview
# clamp. Three surfaces went through hand-written copies of this before (meeting
# transcript, saved analysis results, and the ticket summary, which rendered through
# simple_format and put "###" and "**" on screen as raw characters).
RSpec.describe Neo::MarkdownPreviewComponent, type: :component do
  describe 'the Markdown render' do
    it 'typesets headings, emphasis and lists instead of showing the syntax' do
      render_inline(described_class.new(markdown: "### Kopf\n\n- **fett**\n- zweitens"))

      expect(page).to have_css('h3', text: 'Kopf')
      expect(page).to have_css('ul li strong', text: 'fett')
      expect(page).to have_css('ul li', count: 2)
      # The failure this component exists to prevent: syntax reaching the reader.
      expect(page).to have_no_text('###')
      expect(page).to have_no_text('**fett**')
    end

    # Second gate on top of Lalabase::SafeMarkdown's own specs: no call site may
    # reach the page with an unsanitised string, and this is the only render path.
    it 'drops an <img> and a javascript: link' do
      render_inline(described_class.new(markdown: '![x](http://t/p.png) [bad](javascript:alert(1))'))

      expect(page).to have_no_css('img')
      expect(rendered_content).not_to include('javascript:')
    end

    it 'renders nothing at all for blank Markdown' do
      render_inline(described_class.new(markdown: '   '))

      expect(rendered_content.strip).to be_empty
    end
  end

  describe 'without a clamp' do
    it 'renders the prose block alone — no controller, no toggle' do
      render_inline(described_class.new(markdown: 'Kurz.'))

      expect(page).to have_css('div.md-preview')
      expect(page).to have_no_css('[data-controller="clamp-toggle"]')
      expect(page).to have_no_css('button')
    end

    it 'puts class_name on the prose block itself' do
      render_inline(described_class.new(markdown: 'Kurz.', class_name: 'mt-2'))

      expect(page).to have_css('div.md-preview.mt-2')
    end
  end

  describe 'with a clamp' do
    subject(:render_clamped) do
      render_inline(described_class.new(markdown: 'Lang.', clamp: :short,
                                        more_label: 'Mehr', less_label: 'Weniger',
                                        class_name: 'mb-3'))
    end

    it 'wires the controller to the clamp class the stylesheet defines' do
      render_clamped

      wrapper = page.find('[data-controller="clamp-toggle"]')
      expect(wrapper['data-clamp-toggle-clamped-class']).to eq('md-preview--clamped')
      expect(wrapper[:class]).to include('mb-3')
      expect(page).to have_css('[data-clamp-toggle-target="content"].md-preview')
    end

    # Progressive enhancement, and the reason no spec may assert the clamp class in
    # the SERVER output: without JavaScript the reader gets the full text and no
    # button, never a cut-off block with no way to open it.
    it 'emits the full text unclamped, with the toggle hidden' do
      render_clamped

      expect(page).to have_css('[data-clamp-toggle-target="content"]', text: 'Lang.')
      expect(page).to have_no_css('.md-preview--clamped')
      expect(page).to have_css('button.hidden[data-clamp-toggle-target="toggle"]')
    end

    it 'carries both labels, the collapse one hidden to start with' do
      render_clamped

      expect(page).to have_css('[data-clamp-toggle-target="moreLabel"]', text: 'Mehr', visible: :all)
      expect(page).to have_css('[data-clamp-toggle-target="lessLabel"].hidden', text: 'Weniger',
                                                                                visible: :all)
    end
  end

  describe 'the clamp height' do
    it 'stays at the default for :short' do
      render_inline(described_class.new(markdown: 'x', clamp: :short, more_label: 'a', less_label: 'b'))

      expect(page).to have_no_css('.md-preview--clamp-tall')
    end

    # The modifier sits on the BODY, next to where the clamp class lands — on the
    # wrapper it would style nothing.
    it 'marks the body for :tall' do
      render_inline(described_class.new(markdown: 'x', clamp: :tall, more_label: 'a', less_label: 'b'))

      expect(page).to have_css('[data-clamp-toggle-target="content"].md-preview.md-preview--clamp-tall')
    end
  end

  describe 'sizes' do
    it 'renders the small variant' do
      render_inline(described_class.new(markdown: 'x', size: :sm))
      expect(page).to have_css('.md-preview.md-preview--sm')
    end

    it 'renders the medium variant' do
      render_inline(described_class.new(markdown: 'x', size: :md))
      expect(page).to have_css('.md-preview.md-preview--md')
    end

    it 'adds no size class for :base — the block inherits the page size' do
      render_inline(described_class.new(markdown: 'x', size: :base))

      expect(page).to have_css('.md-preview')
      expect(page).to have_no_css('.md-preview--sm')
      expect(page).to have_no_css('.md-preview--md')
    end
  end

  # A typo used to be a silently unstyled block or an unreadable button — the kind
  # of defect that only shows on the one page nobody opened before the deploy.
  describe 'argument validation' do
    it 'rejects an unknown size' do
      expect { described_class.new(markdown: 'x', size: :large) }
        .to raise_error(ArgumentError, /unknown size/)
    end

    it 'rejects an unknown clamp' do
      expect { described_class.new(markdown: 'x', clamp: :huge, more_label: 'a', less_label: 'b') }
        .to raise_error(ArgumentError, /unknown clamp/)
    end

    it 'rejects a clamp without labels' do
      expect { described_class.new(markdown: 'x', clamp: :short, more_label: 'a') }
        .to raise_error(ArgumentError, /more_label/)
    end
  end
end
