# frozen_string_literal: true

# What this protects: `_claim_note` renders the limiting addendum to EVERY
# statement about a package (jurisdiction, training, retention). That makes it
# the one place where a compliance statement either appears or silently
# disappears.
#
# Why a separate view spec and not through the card: the string guard below is
# a precaution for a group that nobody pluralises today. After the
# `derived_retention` downgrade it is no longer reachable through the card, so a
# request spec could not make it fail, and an untested precaution is just code
# that feels safe.
require 'rails_helper'

RSpec.describe 'organisations/ai_settings/_claim_note', type: :view do
  def render_note(**locals)
    render partial: 'organisations/ai_settings/claim_note', locals: locals
    rendered
  end

  let(:scope) { 'views.organisations.ai_settings.packages.retention_notes' }

  it 'renders the addendum belonging to the value' do
    output = render_note(scope: scope, value: 'none')

    expect(output).to include(I18n.t("#{scope}.none"))
  end

  it 'stays silent for a value the locale file says nothing about' do
    output = render_note(scope: scope, value: 'eu_native')

    expect(output.strip).to be_empty
  end

  # THE line `fallback` exists for at all, and the reason it is NOT written as
  # `t(…) || fallback`. The fallback applies only to a BLANK value ("nichts
  # eingestuft"), never to a set value without an addendum. Otherwise the switch
  # dialog would show the sentence "kein Rechtsraum hinterlegt" under the green
  # badge "Europäisch": the page would contradict itself in two consecutive
  # lines. Exactly the kind of self-contradiction the #437 review removed from
  # this dialog four times.
  it 'never uses the fallback for a value that simply carries no addendum' do
    output = render_note(scope: 'views.organisations.ai_settings.packages.jurisdiction_notes',
                         value: AiPackage::EU_NATIVE, fallback: 'Nichts eingestuft.')

    expect(output).not_to include('Nichts eingestuft.')
    expect(output.strip).to be_empty
  end

  # A blank value means "nichts eingestuft". On the card that stays silent, in
  # the switch dialog it is a statement of its own, hence the optional fallback.
  it 'says nothing for a blank value unless a fallback is passed' do
    expect(render_note(scope: scope, value: nil).strip).to be_empty
  end

  it 'uses the fallback for a blank value when one is passed' do
    output = render_note(scope: scope, value: nil, fallback: 'Nichts eingestuft.')

    expect(output).to include('Nichts eingestuft.')
  end

  it 'interpolates the count into a pluralised addendum' do
    output = render_note(scope: scope, value: 'limited', args: { count: 30 })

    expect(output).to include(I18n.t("#{scope}.limited", count: 30))
    expect(output).to include('30')
  end

  it 'picks the singular branch for exactly one day' do
    output = render_note(scope: scope, value: 'limited', args: { count: 1 })

    expect(output).to include(I18n.t("#{scope}.limited", count: 1))
  end

  # THE reason for the string guard. A pluralised entry looked up WITHOUT `count`
  # returns the raw hash, and `present?` considers it present. Without this line
  # `{:one=>"…", :other=>"…"}` would appear as text on the customer card, in
  # exactly the font size that was chosen for honesty.
  it 'renders nothing rather than a raw locale hash when the count is missing' do
    output = render_note(scope: scope, value: 'limited')

    expect(output).not_to include(':one=>')
    expect(output).not_to include(':other=>')
    expect(output.strip).to be_empty
  end
end
