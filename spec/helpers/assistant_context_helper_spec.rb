# frozen_string_literal: true

require 'rails_helper'

# What:  The marker by which a page NAMES the object it is showing, so the
#        assistant panel can offer to take it over (S4 T2 step 5b, plan §7.3).
# Type:  Helper spec, i.e. one that CI actually runs.
# Why:   The rule has two call sites because #ticket_display_frame has two roots
#        (_ticket_display normally, _ticket_content_for_frame after a generated
#        summary), and the whole point of the helper is that the value, the bound
#        and the gate stay one thing across both. Everything the panel then does
#        with the marker lives in a Stimulus controller, which CI does not run at
#        all -- so this is the last place a wrong bound or a missing gate can be
#        caught by the pipeline rather than by a user.
RSpec.describe AssistantContextHelper do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: create(:user), title: 'Anmeldung')
    end
  end

  # assistant_available? reaches a view as a controller helper_method, so it is
  # not on the module under test and a verifying double cannot stand in for it.
  # Defined on this one view instance rather than switching partial-double
  # verification off for the file: the dependency is real and naming it here is
  # the point -- the gate belongs to the controller, the helper only asks.
  def attributes_for(ticket, available:)
    helper.define_singleton_method(:assistant_available?) { available }
    helper.assistant_context_attributes(ticket).to_s
  end

  it 'names the object, its TYPE and the text the chip will show' do
    markup = attributes_for(ticket, available: true)

    expect(markup).to include(%(data-assistant-context="#{ticket.id}"))
    expect(markup).to include(%(data-assistant-context-type="Ticket"))
    expect(markup).to include(%(data-assistant-context-label="##{ticket.number} Anmeldung"))
  end

  it 'names a meeting with a bounded, escaped one-line title from the registry' do
    meeting = ActsAsTenant.with_tenant(organisation) do
      build_stubbed(:meeting, title: "Planung\n  \"#{'A' * 100}\"")
    end
    markup = attributes_for(meeting, available: true)
    label = Nokogiri::HTML.fragment("<div #{markup}></div>").at_css('div')['data-assistant-context-label']

    expect(markup).to include('data-assistant-context-type="Meeting"', '&quot;')
    expect(label).to start_with("#{I18n.l(meeting.occurred_at.to_date)} · Planung \"")
    expect(label.length).to eq(Neo::Chat::ReferenceChipComponent::MAX_TITLE_CHARS)
    expect(label).not_to include("\n")
  end

  # The type is not decoration: the panel composes the composite key
  # ("Ticket:<uuid>", §7.1) out of the pair, and the collection is addressed by
  # nothing else. Without it the page would name an id and the panel would have to
  # guess what it is an id OF.
  #
  # Fail-closed on the other side of the same coin: a page that names an object
  # the registry does not know names NOTHING. Otherwise the offer would appear for
  # something no route and no chip can carry.
  it 'says nothing at all for a type the reference registry does not know' do
    expect(attributes_for(project, available: true)).to eq('')
  end

  # The label is what the reference CHIP will say once the offer is taken, so it
  # is cut to the chip's bound and not to the system prompt's. Ticket#one_line_title
  # serves both and they are bounded differently (80 against 120), so a title
  # between the two is the one input that tells them apart. Without this the
  # helper could quietly use the wider bound and the offer would promise a text
  # the chip then truncates.
  context 'with a title longer than the chip allows' do
    let(:ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: project, organisation: organisation, creator: create(:user), title: 'A' * 100)
      end
    end

    it "cuts the label to the chip's bound, not the system prompt's" do
      markup = attributes_for(ticket, available: true)
      label = Nokogiri::HTML.fragment("<div #{markup}></div>").at_css('div')['data-assistant-context-label']

      expect(label.length).to eq(Neo::Chat::ReferenceChipComponent::MAX_TITLE_CHARS)
      expect(label).to eq(ticket.one_line_title(max: Neo::Chat::ReferenceChipComponent::MAX_TITLE_CHARS))
      expect(label).not_to eq(ticket.one_line_title(max: 120))
    end
  end

  # The negative half, and the reason the gate lives in the helper rather than at
  # each call site: a door to a lane that is not there is the shape of defect the
  # panel's own gate exists to prevent, and two call sites are two chances to
  # forget it.
  it 'stays away entirely where there is no companion lane to read it' do
    expect(attributes_for(ticket, available: false)).to eq('')
  end

  it 'stays away when there is no ticket at all' do
    expect(attributes_for(nil, available: true)).to eq('')
  end

  # The button's attributes (step 3 of the same plan): the other seam, from the
  # same owner, so the type the button sends and the type the marker names come
  # from one lookup. Gated and fail-closed exactly like the marker.
  describe 'the trigger attributes' do
    def trigger_for(record, available:)
      helper.define_singleton_method(:assistant_available?) { available }
      helper.assistant_trigger_attributes(record).to_s
    end

    it 'hands the panel the type and id over the window-event seam' do
      markup = trigger_for(ticket, available: true)

      expect(markup).to include('data-controller="assistant-trigger"')
      expect(markup).to include('data-assistant-trigger-type-value="Ticket"')
      expect(markup).to include(%(data-assistant-trigger-id-value="#{ticket.id}"))
      expect(markup).to include('data-action="click-&gt;assistant-trigger#adopt"')
    end

    it 'says nothing for an unregistered type, without an assistant, or without a record' do
      expect(trigger_for(project, available: true)).to eq('')
      expect(trigger_for(ticket, available: false)).to eq('')
      expect(trigger_for(nil, available: true)).to eq('')
    end

    # The intent is what makes the panel open in analysis or task mode instead of
    # plain chat. A generic "ask the assistant" button must not carry one by accident,
    # and the meeting entries must carry exactly the spelling the panel reads.
    it 'adds the intent only when a caller names one' do
      meeting = ActsAsTenant.with_tenant(organisation) { build_stubbed(:meeting, title: 'Planung') }
      helper.define_singleton_method(:assistant_available?) { true }

      expect(helper.assistant_trigger_data(meeting)).not_to have_key(:assistant_trigger_intent_value)
      expect(helper.assistant_trigger_data(meeting, intent: nil)).not_to have_key(:assistant_trigger_intent_value)
      expect(helper.assistant_trigger_data(meeting, intent: :analysis)[:assistant_trigger_intent_value]).to eq('analysis')
      expect(helper.assistant_trigger_data(meeting, intent: :'ticket-suggestions')[:assistant_trigger_intent_value])
        .to eq('ticket-suggestions')
    end

    it 'names no intent at all without an assistant' do
      meeting = ActsAsTenant.with_tenant(organisation) { build_stubbed(:meeting, title: 'Planung') }
      helper.define_singleton_method(:assistant_available?) { false }

      expect(helper.assistant_trigger_data(meeting, intent: :analysis)).to be_nil
    end
  end

  # The knowledge objects (doc/assistent_wissen_kontext_plan.md, step 1). The
  # helper itself is type-blind; what these pin is that the registry now names
  # the two types AND that each has a label -- because a marker WITHOUT a label
  # is one the panel skips (pageContexts() wants id, type and label together),
  # so an empty label is not a cosmetic gap, it is a missing offer.
  describe 'the knowledge objects' do
    let(:note) do
      ActsAsTenant.with_tenant(organisation) do
        create(:note, project: project, organisation: organisation, creator: create(:user), title: 'Einarbeitung')
      end
    end

    def document_with(title:)
      ActsAsTenant.with_tenant(organisation) do
        document = create(:document, project: project, organisation: organisation, creator: create(:user))
        version = create(:document_version, document: document, organisation: organisation, title: title)
        document.update!(current_version: version)
        document
      end
    end

    it 'names a note by its type and title' do
      markup = attributes_for(note, available: true)

      expect(markup).to include(%(data-assistant-context="#{note.id}"))
      expect(markup).to include(%(data-assistant-context-type="Note"))
      expect(markup).to include(%(data-assistant-context-label="Einarbeitung"))
    end

    it 'names a document by its type and the current version\'s title' do
      document = document_with(title: 'Angebot 2026')

      markup = attributes_for(document, available: true)

      expect(markup).to include(%(data-assistant-context="#{document.id}"))
      expect(markup).to include(%(data-assistant-context-type="Document"))
      expect(markup).to include(%(data-assistant-context-label="Angebot 2026"))
    end

    # Document#title delegates to the current version and is nil without one.
    # nil would reach the attribute as "", and "" is what makes pageContexts()
    # walk past the marker -- the page would be on a document and offer nothing,
    # silently. So the label falls back to a translated word, in both languages.
    # A page's own word after the title, inside the chip's bound: the preview of
    # an older version says "(aktuelle Version)" so the offer does not promise
    # what is on screen. The title gives way, the suffix never does.
    it 'appends a suffix inside the same bound' do
      long = document_with(title: 'A' * 100)
      helper.define_singleton_method(:assistant_available?) { true }
      markup = helper.assistant_context_attributes(long, suffix: '(aktuelle Version)').to_s
      label = Nokogiri::HTML.fragment("<div #{markup}></div>").at_css('div')['data-assistant-context-label']

      expect(label).to end_with(' (aktuelle Version)')
      expect(label.length).to be <= Neo::Chat::ReferenceChipComponent::MAX_TITLE_CHARS
      expect(helper.assistant_context_attributes(long, suffix: nil).to_s).not_to include('aktuelle')
    end

    it 'still labels a document that has no current version' do
      document = ActsAsTenant.with_tenant(organisation) do
        create(:document, project: project, organisation: organisation, creator: create(:user))
      end

      markup = attributes_for(document, available: true)
      label = Nokogiri::HTML.fragment("<div #{markup}></div>").at_css('div')['data-assistant-context-label']

      expect(label).to eq(I18n.t('models.document.untitled', locale: :de))
      expect(I18n.t('models.document.untitled', locale: :en, fallback: false)).to eq('Untitled')
    end
  end

  # A title is free text and reaches the DOM as an attribute value. Rails escapes
  # it here; asserting it means a later hand-rolled string interpolation cannot
  # quietly replace tag.attributes.
  it 'escapes a title that would otherwise close the attribute' do
    ActsAsTenant.with_tenant(organisation) { ticket.update!(title: %(Ex" onmouseover="x)) }

    markup = attributes_for(ticket, available: true)

    expect(markup).not_to include('onmouseover="x"')
    expect(markup).to include('&quot;')
  end
end
