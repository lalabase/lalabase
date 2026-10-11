# frozen_string_literal: true

require 'rails_helper'
require 'prism'

# Guard for Notification.bulk_transition!: a state change through a bare
# update_all skips Notification's after_commit, so the org switcher signal
# (Notifications::UnreadSignals) of every touched recipient went stale until
# the next page load. Seven bulk writers had to remember that by hand; now
# only bulk_transition! may call update_all with a state, and it refreshes.
#
# Reads the code with Prism, so a call spread over several lines counts too.
# Notification is the only model whose state is changed in bulk today; if
# another model needs update_all(state: ...) for its own column, add that file
# to `allowed` with the reason.
RSpec.describe 'Notification bulk state changes go through bulk_transition!', :ci_guard do
  let(:allowed) do
    { 'app/models/notification.rb' => 'the one bare update_all, inside bulk_transition!' }
  end

  def state_update_alls(path)
    found = []
    visit = lambda do |node|
      if node.is_a?(Prism::CallNode) && node.name == :update_all
        keys = Array(node.arguments&.arguments).grep(Prism::KeywordHashNode)
                                               .flat_map(&:elements)
                                               .map { |el| el.key.respond_to?(:unescaped) ? el.key.unescaped : nil }
        found << node.location.start_line if keys.include?('state')
      end
      node.compact_child_nodes.each { |child| visit.call(child) }
    end
    visit.call(Prism.parse_file(path).value)
    found
  end

  it 'finds no update_all with a state outside bulk_transition!' do
    offenders = Dir[Rails.root.join('{app,lib}/**/*.rb')].flat_map do |file|
      relative = Pathname(file).relative_path_from(Rails.root).to_s
      next [] if allowed.key?(relative)

      state_update_alls(file).map { |line| "#{relative}:#{line}" }
    end

    expect(offenders).to be_empty, <<~MSG
      update_all with a state skips Notification's after_commit, so the org switcher signal goes stale.
      Use relation.bulk_transition!(state: ..., ...) instead:
        #{offenders.join("\n  ")}
    MSG
  end

  it 'recognises the shapes it guards against' do
    sample = Tempfile.new(['guard', '.rb'])
    sample.write(<<~RUBY)
      scope.update_all(state: 'read', read_at: Time.current)
      scope.update_all(
        state: :archived,
        archived_at: Time.current
      )
      scope.update_all(project_id: nil)
    RUBY
    sample.close

    expect(state_update_alls(sample.path)).to eq([1, 2])
  ensure
    sample&.unlink
  end
end
