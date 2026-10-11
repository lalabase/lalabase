# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::Context, the per-call context every tool reads.
# Type: Service spec.
# Why:  Three reaches share it (project, org-thread scope, token reach) and every
#       tool branches on which one is set. project next to scope is the pinned
#       single-project path (list_tickets_spec), but a token reach next to either
#       would make the branch a coin flip, so the constructor refuses that, right
#       where a builder goes wrong.
RSpec.describe Lalabase::Tools::Context do
  let(:project) { instance_double(Project) }
  let(:scope) { instance_double(Lalabase::Tools::Scope) }
  let(:reach) { instance_double(PersonalAccessToken::Reach) }

  it 'accepts each reach on its own, and none at all' do
    expect(described_class.new(project: project).project).to be(project)
    expect(described_class.new(scope: scope).scope).to be(scope)
    expect(described_class.new(reach: reach).reach).to be(reach)
    expect(described_class.new.project).to be_nil
  end

  it 'keeps project next to scope (the pinned single-project path)' do
    context = described_class.new(project: project, scope: scope)
    expect(context.project).to be(project)
    expect(context.scope).to be(scope)
  end

  it 'refuses a token reach next to a project or a scope, at construction' do
    expect { described_class.new(project: project, reach: reach) }.to raise_error(ArgumentError, /reach\+project/)
    expect { described_class.new(scope: scope, reach: reach) }.to raise_error(ArgumentError, /reach\+scope/)
    expect { described_class.new(project: project, scope: scope, reach: reach) }
      .to raise_error(ArgumentError, /reach\+project\+scope/)
  end
end
