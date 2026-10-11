# frozen_string_literal: true

require 'rails_helper'

# The seeds ship to every self-hosted instance, so two things may never come back:
#
# 1. Deleting. Until S0 (doc/oss_core_split_plan.md §8) db/seeds.rb opened with
#    `delete_all` on six tables and reset every sequence. `db:seed` on a live instance
#    wiped its tickets.
# 2. Personal data. The same file created the instance admin with the owner's own
#    address as login AND password. Anyone who read the repository could sign in to
#    /admin of any instance seeded from it.
#
# Every address in the seeds uses example.com (RFC 2606): it can never belong to
# anyone, and a mail sent to it goes nowhere.
RSpec.describe 'Seeds guard' do
  let(:seed_files) do
    [Rails.root.join('db/seeds.rb'), *Dir[Rails.root.join('db/seeds/**/*.{rb,yml}')]].map(&:to_s)
  end

  let(:deleting_call) { /\b(delete_all|destroy_all|delete_by|destroy_by|truncate|reset_pk_sequence!)\b|TRUNCATE|DELETE FROM/ }
  let(:email_address) { /[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}/ }

  def relative(path)
    Pathname(path).relative_path_from(Rails.root).to_s
  end

  it 'reads the seed files it guards' do
    expect(seed_files.map { |file| relative(file) }).to include('db/seeds.rb', 'db/seeds/demo.rb')
  end

  it 'deletes nothing' do
    offenders = seed_files.flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, index|
        "#{relative(file)}:#{index + 1}: #{line.strip}" if line.match?(deleting_call)
      end
    end

    expect(offenders).to be_empty,
                         "The seeds run on live instances and must never delete:\n#{offenders.join("\n")}"
  end

  it 'names no address outside example.com' do
    offenders = seed_files.flat_map do |file|
      foreign = File.read(file).scan(email_address).reject { |address| address.end_with?('@example.com') }
      foreign.map { |address| "#{relative(file)}: #{address}" }
    end

    expect(offenders).to be_empty,
                         "Seeds hold no personal data; use @example.com:\n#{offenders.join("\n")}"
  end
end
