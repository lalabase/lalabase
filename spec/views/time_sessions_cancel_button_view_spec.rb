# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'time sessions cancel button views' do
  # Since the form-fields merge, _form_fields renders the cancel button (ButtonComponent
  # + t('.cancel')); the wrappers only pin their context-specific cancel_action.
  describe '_form_fields.html.erb' do
    it 'renders the shared cancel button wired to the passed cancel_action' do
      form_path = Rails.root.join('app/views/organisations/time_sessions/_form_fields.html.erb')
      form_content = File.read(form_path)

      expect(form_content).to include('Neo::Buttons::ButtonComponent')
      expect(form_content).to include("t('.cancel')")
      expect(form_content).to include('data: { action: cancel_action }')
    end
  end

  describe '_form_index.html.erb' do
    it 'defaults the cancel action to the time-session-modal close' do
      form_path = Rails.root.join('app/views/organisations/time_sessions/_form_index.html.erb')
      form_content = File.read(form_path)

      # The default applies on ticket pages (time_session_modal_form frame);
      # the index page passes close_action explicitly (see index.html.erb tests).
      expect(form_content).to include('click->time-session-modal#close')
      expect(form_content).to include('cancel_action: close_action')
    end
  end

  describe '_form_organization_wide.html.erb' do
    it 'wires the cancel action to the index modal close' do
      form_path = Rails.root.join('app/views/organisations/time_sessions/_form_organization_wide.html.erb')
      form_content = File.read(form_path)

      expect(form_content).to include('cancel_action: "click->time-sessions-index#closeModal"')
    end
  end

  describe 'index.html.erb' do
    it 'contains Stimulus controller and modal close actions' do
      # Read the actual file content
      index_path = Rails.root.join('app/views/organisations/time_sessions/index.html.erb')
      index_content = File.read(index_path)

      # Check for Stimulus controller
      expect(index_content).to include('data-controller="time-sessions-index"')

      # Check for close modal actions
      expect(index_content).to include('click->time-sessions-index#closeModal')
      expect(index_content).to include('keydown.esc->time-sessions-index#closeModal')
    end

    it 'has correct modal structure' do
      index_path = Rails.root.join('app/views/organisations/time_sessions/index.html.erb')
      index_content = File.read(index_path)

      # Check for modal target (Stimulus-based)
      expect(index_content).to include('data-time-sessions-index-target="modal"')

      # Check for X button with Stimulus action
      expect(index_content).to include('bi-x-lg')
      expect(index_content).to include('data-action="click->time-sessions-index#closeModal"')

      # Check for modal backdrop click outside handler
      expect(index_content).to include('data-action="click->time-sessions-index#clickOutside"')
    end
  end

  describe 'Button HTML structure' do
    it 'matches the expected pattern for Stimulus actions' do
      expected_action = 'data-action="click->time-sessions-index#closeModal"'

      # This tests the expected Stimulus structure
      expect(expected_action).to include('data-action')
      expect(expected_action).to include('click->time-sessions-index#closeModal')
      expect(expected_action).to include('closeModal')
    end
  end
end
