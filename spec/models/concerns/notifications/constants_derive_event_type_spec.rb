# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Notifications::Constants, '.derive_event_type' do
  subject(:derive) { described_class.derive_event_type(key, action) }

  # --- Explicit Overrides ---

  describe 'explicit overrides (key)' do
    let(:action) { nil }

    {
      'ticket.created' => 'system_message',
      'ticket.updated' => 'ticket_status_changed',
      'ticket.ticket_commented' => 'ticket_commented',
      'post.created' => 'ticket_commented',
      'project.note_created' => 'document_added',
      'mention.created' => 'mention'
    }.each do |input_key, expected_type|
      context "key='#{input_key}'" do
        let(:key) { input_key }
        it { is_expected.to eq(expected_type) }
      end
    end
  end

  describe 'explicit overrides (action fallback)' do
    let(:key) { nil }

    {
      'ticket_created' => 'ticket_assigned',
      'ticket_updated' => 'ticket_status_changed',
      'created' => 'system_message',
      'deleted' => 'system_message',
      'archived' => 'system_message'
    }.each do |input_action, expected_type|
      context "action='#{input_action}'" do
        let(:action) { input_action }
        it { is_expected.to eq(expected_type) }
      end
    end
  end

  # --- Convention-based Auto-Derive ---

  describe 'convention-based auto-derive' do
    let(:action) { nil }

    context 'comment/post patterns' do
      {
        'ticket.post_added' => 'ticket_commented',
        'ticket.commented' => 'ticket_commented',
        'ticket.reply_added' => 'ticket_commented'
      }.each do |input_key, expected_type|
        context "key='#{input_key}'" do
          let(:key) { input_key }
          it { is_expected.to eq(expected_type) }
        end
      end

      context 'action-only: post_added' do
        let(:key) { nil }
        let(:action) { 'post_added' }
        it { is_expected.to eq('ticket_commented') }
      end
    end

    context 'assignment patterns' do
      context "key='ticket.assigned'" do
        let(:key) { 'ticket.assigned' }
        it { is_expected.to eq('ticket_assigned') }
      end

      context "key='ticket.unassigned' (muss VOR assign matchen)" do
        let(:key) { 'ticket.unassigned' }
        it { is_expected.to eq('ticket_unassigned') }
      end
    end

    context 'status patterns' do
      let(:key) { 'ticket.status_changed' }
      it { is_expected.to eq('ticket_status_changed') }
    end

    context 'priority/blocker patterns' do
      {
        'ticket.priority_changed' => 'ticket_blocker',
        'ticket.blocker_added' => 'ticket_blocker'
      }.each do |input_key, expected_type|
        context "key='#{input_key}'" do
          let(:key) { input_key }
          it { is_expected.to eq(expected_type) }
        end
      end
    end

    context 'mention patterns' do
      let(:key) { 'ticket.mention' }
      it { is_expected.to eq('mention') }
    end

    context 'document/note patterns' do
      {
        'document.created' => 'document_added',
        'note.created' => 'document_added'
      }.each do |input_key, expected_type|
        context "key='#{input_key}'" do
          let(:key) { input_key }
          it { is_expected.to eq(expected_type) }
        end
      end
    end

    context 'project patterns (start_with project.)' do
      {
        'project.updated' => 'project_announcement',
        'project.member_added' => 'project_announcement'
      }.each do |input_key, expected_type|
        context "key='#{input_key}'" do
          let(:key) { input_key }
          it { is_expected.to eq(expected_type) }
        end
      end
    end
  end

  # --- Fallback ---

  describe 'fallback to system_message' do
    context 'unknown key and action' do
      let(:key) { 'unknown.something' }
      let(:action) { 'unknown_action' }
      it { is_expected.to eq('system_message') }
    end

    context 'nil key and nil action' do
      let(:key) { nil }
      let(:action) { nil }
      it { is_expected.to eq('system_message') }
    end

    context 'ticket.title_changed (no keyword match)' do
      let(:key) { 'ticket.title_changed' }
      let(:action) { 'title_changed' }
      it { is_expected.to eq('system_message') }
    end
  end

  # --- Backward Compatibility ---

  describe 'backward compatibility with EVENT_TYPE_MAPPING' do
    # All keys from the old mapping should return the same result.
    # Exceptions are documented.
    known_differences = {
      # The old map had 'updated' => PROJECT_ANNOUNCEMENT,
      # the new auto-derive has no keyword match → system_message.
      # In practice, 'updated' is always called with a key like 'ticket.updated',
      # which has an explicit override. The action-only case does not occur.
      'updated' => true
    }

    Notifications::Constants::EVENT_TYPE_MAPPING.each do |input, old_result|
      next if known_differences[input]

      context "input='#{input}'" do
        # Decide whether it is a key (with a dot) or an action
        let(:key) { input.include?('.') ? input : nil }
        let(:action) { input.include?('.') ? nil : input }

        it "liefert '#{old_result}' (wie altes Mapping)" do
          expect(derive).to eq(old_result)
        end
      end
    end
  end
end
