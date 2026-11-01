# frozen_string_literal: true

require 'rails_helper'

# What: Actors::CreateTicketRelation and Actors::DestroyTicketRelation are called
#   only from the files on CALLERS, a closed list. A caller on the list that no
#   longer calls fails too.
# Why: the two actors check no rights. They trust that the caller already decided
#   who may touch both tickets, and which relation it found for whom. A new caller
#   therefore means reading that decision first: add the file here only after it
#   has made it, the same way the existing caller does.
# Not seen: a name built at run time (constantize, send). Comment lines do not
#   count, a mention in a string does.
module TicketRelationActorCallersGuard
  ROOTS = %w[app lib].freeze
  ACTOR_FILES = %w[
    app/services/actors/create_ticket_relation.rb
    app/services/actors/destroy_ticket_relation.rb
  ].freeze

  CALLERS = %w[
    app/controllers/organisations/tickets/relations_controller.rb
  ].freeze

  # Without the namespace too: code inside module Actors can name them bare.
  ACTOR_NAME = /\b(?:Create|Destroy)TicketRelation\b/
  COMMENT_LINE = /\A\s*(?:#|<%#)/

  # [line number, text] of every line that names one of the actors
  def self.findings(source)
    source.lines.each_with_index.filter_map do |line, index|
      next if line.match?(COMMENT_LINE)

      [index + 1, line.strip] if line.match?(ACTOR_NAME)
    end
  end

  def self.files
    ROOTS.flat_map { |root| Dir[Rails.root.join("#{root}/**/*.{rb,erb,rake}")] }
         .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }
         .sort - ACTOR_FILES
  end

  def self.callers
    files.reject { |file| findings(File.read(Rails.root.join(file))).empty? }
  end
end

RSpec.describe 'Ticket relation actors have known callers', :ci_guard, type: :architecture do
  it 'finds no caller outside the closed list' do
    strangers = TicketRelationActorCallersGuard.callers - TicketRelationActorCallersGuard::CALLERS

    expect(strangers).to be_empty,
                         "These call a ticket relation actor, which checks no rights:\n#{strangers.join("\n")}\n\n" \
                         'Decide the rights on both tickets in the caller, then add it to ' \
                         'TicketRelationActorCallersGuard::CALLERS.'
  end

  it 'keeps no caller that no longer calls' do
    stale = TicketRelationActorCallersGuard::CALLERS - TicketRelationActorCallersGuard.callers

    expect(stale).to be_empty, "Remove these from TicketRelationActorCallersGuard::CALLERS:\n#{stale.join("\n")}"
  end

  it 'reads the actors and templates too, or the scan proves nothing' do
    files = TicketRelationActorCallersGuard.files

    expect(files).to include(*TicketRelationActorCallersGuard::CALLERS)
    expect(files).to include('app/services/tickets/cycle_check.rb')
    expect(files).to(be_any { |file| file.end_with?('.erb') })
    expect(files).not_to include(*TicketRelationActorCallersGuard::ACTOR_FILES)
  end

  describe 'what counts as a call' do
    def call?(source)
      TicketRelationActorCallersGuard.findings(source).any?
    end

    it 'flags each actor, with or without the namespace' do
      expect(call?("Actors::CreateTicketRelation.call(ticket: a)\n")).to be(true)
      expect(call?("::Actors::DestroyTicketRelation.call(ticket: a)\n")).to be(true)
      expect(call?("CreateTicketRelation.new(ticket: a).call\n")).to be(true)
    end

    it 'flags a call in a template' do
      expect(call?("<% ::Actors::DestroyTicketRelation.call(ticket: a) %>\n")).to be(true)
    end

    it 'gives the line of the call' do
      findings = TicketRelationActorCallersGuard.findings("a = 1\nActors::CreateTicketRelation.call\n")

      expect(findings).to eq([[2, 'Actors::CreateTicketRelation.call']])
    end

    it 'ignores comments and longer names' do
      expect(call?("# Actors::CreateTicketRelation holds a lock\n")).to be(false)
      expect(call?("  # and Actors::DestroyTicketRelation\n")).to be(false)
      expect(call?("<%# Actors::CreateTicketRelation %>\n")).to be(false)
      expect(call?("CreateTicketRelationJob.perform_later\n")).to be(false)
    end
  end
end
