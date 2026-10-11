# frozen_string_literal: true

require 'rails_helper'

# The purchased theme JavaScript must stay out of the open-source codebase.
# Scan source files, including Ruby-generated markup. The generated deployment
# manifest is deliberately excluded; asset precompilation replaces it.
RSpec.describe 'No paid theme JavaScript', type: :model do
  let(:legacy_types) do
    %w[toggle tabs indicator tabs-container slider navtop navbar snackbar dialogs
       sheets collapse accordion-container collapsed dropdown dropdownmenu toggle-active]
  end

  def legacy_hook?(source)
    types = Regexp.union(legacy_types)
    value = /:?(?:"(?:#{types})"|'(?:#{types})')|:(?:#{types})(?![\w-])/
    attribute = /\bdata[-_]type["']?\s*(?:=>|[:=])\s*#{value}/
    # Quoted values may contain interpolation braces before the type key.
    hash_token = /[^{}"']|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/m
    data_hash = /\bdata["']?\s*(?:=>|:)\s*\{#{hash_token}*?["']?\btype["']?\s*(?:=>|:)\s*#{value}/m
    source.match?(attribute) || source.match?(data_hash)
  end

  def source_files
    paths = %w[app config lib].flat_map do |root|
      Dir.glob(Rails.root.join(root, '**', '*.{rb,rake,erb,js,mjs,html,yml,yaml,json}'))
    end
    paths.reject { |path| path == Rails.root.join('config/manifest.json').to_s }
  end

  it 'has no theme JavaScript directory' do
    expect(Rails.root.join('app/javascript/tailwind')).not_to exist
  end

  it 'has no theme module references, including imports, pins and precompile entries' do
    offenders = source_files.select { |path| File.read(path).match?(%r{\btailwind/}) }

    expect(offenders).to be_empty, "Remove theme module references from:\n#{offenders.join("\n")}"
  end

  it 'has no legacy behavior hooks in source files' do
    offenders = source_files.select { |path| legacy_hook?(File.read(path)) }

    expect(offenders).to be_empty, "Use existing Stimulus controllers instead:\n#{offenders.join("\n")}"
  end

  it 'detects every retired hook in markup and Ruby data hashes' do
    legacy_types.each do |type|
      [
        %(data-type="#{type}"),
        %(data-type='#{type}'),
        %('data-type' => '#{type}'),
        %(data: { type: "#{type}" }),
        %(data: {\n  target: '#menu',\n  type: :"#{type}"\n}),
        %('data' => { 'type' => '#{type}' })
      ].each do |source|
        expect(legacy_hook?(source)).to be(true), source
      end
    end
  end

  it 'detects hooks after interpolated data values and plain symbol values' do
    expect(legacy_hook?(%(data: { target: "#menu-\#{id}", type: "dropdown" }))).to be(true)
    expect(legacy_hook?('data: { type: :dropdown }')).to be(true)
  end

  it 'permits smooth scrolling and the existing Stimulus mechanisms' do
    [
      %(data-type="smoothscroll"),
      %(data: { type: 'smoothscroll' }),
      %(data-controller="neo-dropdown"),
      %(data: { controller: 'toggle', action: 'click->toggle#toggle' }),
      %(data-controller="details-autoclose"),
      %(data-type-card="notes"),
      %(data-type="tabs-custom"),
      %(data: { type: 'dropdown-choice' }),
      %(data: { type: :dropdown_choice }),
      %(type: 'button')
    ].each do |source|
      expect(legacy_hook?(source)).to be(false), source
    end
  end
end
