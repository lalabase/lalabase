# frozen_string_literal: true

require 'rails_helper'

# Guards the M8.3.9 i18n rename (jobs.openai_response → jobs.ai_chat) and the
# generic_error bugfix. ChatResponseJob renders its error, prompt and tool copy in the
# chat's locale (DE or EN), but the job specs only exercise the default (DE)
# locale — so a missing or mis-renamed key on the EN side would regress
# silently. That is exactly the bug class L3 fixed (a key present in NO locale).
RSpec.describe 'jobs.ai_chat locale parity' do
  # system_prompt and tool_hint left this list with projekt_chat_abbau: they were the
  # per-project chat's framing and its tool sentence, and ChatResponseJob has one
  # surface left. The assistant_* pair is what it renders now.
  ai_chat_keys = %w[unauthorized api_error service_unavailable generic_error injection_guard
                    tool_limit_reached assistant_system_prompt assistant_tool_hint]

  %i[de en].each do |locale|
    ai_chat_keys.each do |key|
      it "defines a present jobs.ai_chat.#{key} in #{locale} (no fallback masking)" do
        # fallback: false pins THIS locale. Both I18n.t (leaf) and I18n.exists?
        # follow the DE fallback otherwise, so a key missing only in EN would
        # resolve via DE and the assertion would pass — hiding the gap.
        msg = I18n.t("jobs.ai_chat.#{key}", locale: locale, fallback: false)
        expect(msg).to be_present
        expect(msg.downcase).not_to include('translation missing')
      end
    end
  end

  # The scope hint carries an interpolation, so it cannot ride in the list above:
  # without the argument I18n raises MissingInterpolationArgument, which is a
  # different failure than the missing key this guard is about. Pinned here so a
  # key missing in BOTH locales cannot hide behind the surface-profile table,
  # whose cells compare I18n.t(key) with I18n.t(key).
  %i[de en].each do |locale|
    it "defines a present jobs.ai_chat.assistant_scope_hint in #{locale} (no fallback masking)" do
      msg = I18n.t('jobs.ai_chat.assistant_scope_hint', locale: locale, fallback: false, project: 'x')
      expect(msg).to be_present
      expect(msg.downcase).not_to include('translation missing')
    end
  end

  # Nested leaf keys, one leaf each, per locale: the persistent per-user style
  # directives (one per level × dimension — a missing level would render
  # "translation missing" straight into the system prompt). These are the ONLY
  # style source since 2026-07-19; the per-answer regenerate nudges are gone.
  %i[de en].each do |locale|
    %w[technicality length].each do |dimension|
      [1, 2, 3].each do |level|
        it "defines a present jobs.ai_chat.style.#{dimension}.#{level} in #{locale}" do
          msg = I18n.t("jobs.ai_chat.style.#{dimension}.#{level}", locale: locale, fallback: false)
          expect(msg).to be_present
          expect(msg.downcase).not_to include('translation missing')
        end
      end
    end
  end

  it 'defines the identical jobs.ai_chat.style.technicality / length key sets in DE and EN' do
    %w[technicality length].each do |dimension|
      de_keys = I18n.with_locale(:de) { I18n.t("jobs.ai_chat.style.#{dimension}").keys.sort }
      en_keys = I18n.with_locale(:en) { I18n.t("jobs.ai_chat.style.#{dimension}").keys.sort }
      expect(de_keys).to eq(en_keys)
    end
  end

  it 'defines the identical jobs.ai_chat key set in DE and EN (no drift)' do
    de_keys = I18n.with_locale(:de) { I18n.t('jobs.ai_chat').keys.sort }
    en_keys = I18n.with_locale(:en) { I18n.t('jobs.ai_chat').keys.sort }
    expect(de_keys).to eq(en_keys)
  end

  # The removed one-off nudges must stay removed in BOTH locales — a leftover
  # leaf in one of them would be dead copy that reads as a live feature.
  it 'defines no jobs.ai_chat.regenerate leaf in either locale' do
    %i[de en].each { |locale| expect(I18n.exists?('jobs.ai_chat.regenerate', locale)).to be(false) }
  end
  # The tool hint is what makes the model AWARE of the tools; a hint that forgets them
  # means the tools are registered and never called. And a hint that forgets the frame
  # of reference produces the failure the story set out to fix in a new shape: a number
  # that covers part of the estate presented as a number for all of it.
  #
  # projekt_chat_abbau moved this guarantee from `tool_hint` (the per-project chat's
  # sentence, deleted with its only caller) onto `assistant_tool_hint`. Moved, not
  # dropped: the frame of reference is a DIFFERENT one here -- the assistant's tools
  # read across every project the asker may read, so the hint has to say that instead
  # of "this one project", and the answer must name the project per statement.
  describe 'assistant_tool_hint names the tools and their frame of reference' do
    %i[de en].each do |locale|
      it "names list_tickets and get_ticket in #{locale}" do
        hint = I18n.t('jobs.ai_chat.assistant_tool_hint', locale: locale, fallback: false)
        expect(hint).to include('list_tickets')
        expect(hint).to include('get_ticket')
      end

      it "points at the exact count instead of an estimate in #{locale}" do
        hint = I18n.t('jobs.ai_chat.assistant_tool_hint', locale: locale, fallback: false)
        expect(hint.downcase).to include(locale == :de ? 'exakte zahl' : 'exact number')
      end
    end

    it 'names the org-wide frame of reference in de' do
      hint = I18n.t('jobs.ai_chat.assistant_tool_hint', locale: :de, fallback: false)
      expect(hint).to include('über alle Projekte, die die fragende Person lesen darf')
      expect(hint).to include('das jeweilige Projekt im Text')
    end

    it 'names the org-wide frame of reference in en' do
      hint = I18n.t('jobs.ai_chat.assistant_tool_hint', locale: :en, fallback: false)
      expect(hint).to include('across every project the asking person may read')
      expect(hint).to include('name the respective project in the text')
    end

    # Lalabase's own help (doc/product_knowledge_plan.md, S2). Registered and never named, the
    # three tools would not be called; and the sentence "each row carries its project" needs
    # its one exception said where the rule is, or the model invents a project for a help page.
    %i[de en].each do |locale|
      it "names the three help tools in #{locale}" do
        hint = I18n.t('jobs.ai_chat.assistant_tool_hint', locale: locale, fallback: false)
        expect(hint).to include('search_help', 'help_contents', 'get_help_page')
      end
    end

    # The rule the first real run broke (12.09.2026): with three hits that merely shared a word
    # the model decided the help had nothing and answered from its own knowledge. The hint names
    # the case the old wording left out, a search that finds something beside the point, and
    # sends the model to the contents list for it.
    it 'sends the model to help_contents when no hit fits, in de and en' do
      %i[de en].each do |locale|
        hint = I18n.t('jobs.ai_chat.assistant_tool_hint', locale: locale, fallback: false)
        expect(hint).to include('help_contents')
        expect(hint).to match(/passt keiner der Treffer|none of the hits fits/)
      end
    end

    it 'says help pages belong to no project, in de and en' do
      expect(I18n.t('jobs.ai_chat.assistant_tool_hint', locale: :de, fallback: false))
        .to include('Hilfeseiten gehören zu keinem Projekt')
      expect(I18n.t('jobs.ai_chat.assistant_tool_hint', locale: :en, fallback: false))
        .to include('help pages belong to no project')
    end

    it 'names how to use Lalabase as a subject in the system prompt, in de and en' do
      expect(I18n.t('jobs.ai_chat.assistant_system_prompt', locale: :de, fallback: false))
        .to include('zur Bedienung von Lalabase')
      expect(I18n.t('jobs.ai_chat.assistant_system_prompt', locale: :en, fallback: false))
        .to include('how to use Lalabase')
    end

    # The five code tools are the ONE exception to the sentence above, and the
    # code hint is where that exception is stated. Offered together or not at all
    # (ChatResponseJob#tool_hint), so the pair is pinned together.
    %i[de en].each do |locale|
      it "says the code tools answer for exactly one project in #{locale}" do
        hint = I18n.t('jobs.ai_chat.assistant_tool_hint_code', locale: locale, fallback: false)
        expect(hint).to include('search_code_symbols')
        expect(hint).to include(locale == :de ? 'GENAU EIN Projekt' : 'EXACTLY ONE project')
      end
    end
  end
end
