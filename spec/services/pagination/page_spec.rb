# frozen_string_literal: true

require 'rails_helper'

# What:  The arithmetic of one page of a list, and the reading of the page number.
# Type:  Service spec; the relation examples read real rows.
# Why:   Every paged list of the web interface and the admin area goes through
#        this object since 18.11.2026 (it replaced a gem). A wrong number here is
#        a list that skips rows or shows them twice, on every screen at once.
# The numbers of the first block were held against the gem while both existed:
# 40 000 random lists, no difference.
RSpec.describe Pagination::Page do
  def page(count:, page: 1, limit: 20, **)
    described_class.new(count: count, page: page, limit: limit, **)
  end

  describe 'the numbers of a page' do
    it 'names the rows of a page in the middle' do
      current = page(count: 291, page: 5)

      expect(current).to have_attributes(pages: 15, offset: 80, from: 81, to: 100, prev: 4, next: 6)
    end

    it 'has no page before the first' do
      expect(page(count: 291, page: 1)).to have_attributes(offset: 0, from: 1, to: 20, prev: nil, next: 2)
    end

    it 'ends a half-filled last page at the last row and has no page after it' do
      expect(page(count: 291, page: 15)).to have_attributes(offset: 280, from: 281, to: 291, prev: 14, next: nil)
    end

    # The boundary where an off-by-one adds an empty page: n - 1, n, n + 1 rows.
    it 'counts one page for exactly one page of rows, and a second for one row more' do
      expect(page(count: 19).pages).to eq(1)
      expect(page(count: 20).pages).to eq(1)
      expect(page(count: 21).pages).to eq(2)
      expect(page(count: 20)).to have_attributes(to: 20, next: nil)
      expect(page(count: 21, page: 2)).to have_attributes(from: 21, to: 21)
    end

    it 'gives a list without rows one empty page' do
      expect(page(count: 0)).to have_attributes(page: 1, pages: 1, offset: 0, from: 0, to: 0, prev: nil, next: nil)
    end

    it 'takes the count and the size as text, the way a query hands them over' do
      expect(page(count: '45', limit: '10')).to have_attributes(count: 45, limit: 10, pages: 5)
    end

    # Kernel#Integer alone reads '010' as eight and raises on '08' and '09'.
    it 'reads text as decimal, also with a leading zero' do
      expect(page(count: '045', limit: '010')).to have_attributes(count: 45, limit: 10)
      expect(page(count: '09', limit: '08')).to have_attributes(count: 9, limit: 8)
    end

    it 'raises for a count that is no whole number' do
      expect { page(count: 'abc') }.to raise_error(ArgumentError, /count/)
      expect { page(count: nil) }.to raise_error(ArgumentError, /count/)
    end

    it 'cannot be changed after it is built' do
      expect(page(count: 5)).to be_frozen
    end
  end

  describe 'a page size nobody can page by' do
    [0, -1, nil, 'abc'].each do |limit|
      it "raises for #{limit.inspect}: the size is the caller's, not the visitor's" do
        expect { page(count: 5, limit: limit) }.to raise_error(ArgumentError, /limit/)
      end
    end
  end

  describe 'the page number of a request' do
    {
      nil => 1, '' => 1, '0' => 1, '-3' => 1, 'abc' => 1, '3abc' => 3, '2' => 2, 2 => 2, 2.9 => 2,
      Float::INFINITY => 1, Float::NAN => 1, true => 1,
      ['2'] => 1, { 'a' => '2' } => 1, ActionController::Parameters.new(a: '2') => 1
    }.each do |value, expected|
      it "reads #{value.inspect} as page #{expected}" do
        expect(described_class.number(value)).to eq(expected)
        expect(page(count: 100, page: value).page).to eq(expected)
      end
    end
  end

  describe 'the page size of a request' do
    {
      nil => nil, '' => nil, '0' => nil, '-3' => nil, 'abc' => nil, '20' => 20, '010' => 10, 20 => 20,
      ['20'] => nil, { 'a' => '20' } => nil, ActionController::Parameters.new(a: '20') => nil
    }.each do |value, expected|
      it "reads #{value.inspect} as #{expected.inspect}" do
        expect(described_class.size(value)).to eq(expected)
      end
    end
  end

  describe 'a page behind the last one' do
    context 'by default' do
      subject(:current) { page(count: 45, page: 9) }

      it 'is an empty page that links back to the last one' do
        expect(current).to be_past_end
        expect(current).to have_attributes(page: 9, pages: 3, from: 0, to: 0, prev: 3, next: nil)
      end

      it 'marks no page of the bar as the current one' do
        expect(current.series).to eq([1, 2, 3])
      end

      it 'is not what the last page itself is' do
        expect(page(count: 45, page: 3)).not_to be_past_end
        expect(page(count: 45, page: 4)).to be_past_end
      end
    end

    context 'with past_end: :last' do
      it 'is the last page' do
        current = page(count: 45, page: 9, past_end: :last)

        expect(current).not_to be_past_end
        expect(current).to have_attributes(page: 3, from: 41, to: 45, prev: 2, next: nil)
      end

      it 'is page 1 of a list without rows' do
        expect(page(count: 0, page: 9, past_end: :last)).to have_attributes(page: 1, from: 0, to: 0)
      end
    end

    it 'knows no third answer' do
      expect { page(count: 45, past_end: :raise) }.to raise_error(ArgumentError, /past_end/)
    end
  end

  describe '#with_page' do
    it 'is the same list on another page, with the same answer behind the end' do
      moved = page(count: 45, page: 1, past_end: :last).with_page(9)

      expect(moved).to have_attributes(count: 45, limit: 20, page: 3)
    end
  end

  describe '#series' do
    it 'lists every page while they fit' do
      expect(page(count: 200, page: 4).series).to eq([1, 2, 3, '4', 5, 6, 7, 8, 9, 10])
    end

    it 'keeps the first and the last page and marks what it leaves out' do
      expect(page(count: 600, page: 12).series).to eq([1, :gap, 10, 11, '12', 13, 14, 15, :gap, 30])
    end

    it 'leaves nothing out next to the first pages' do
      expect(page(count: 600, page: 2).series).to eq([1, '2', 3, 4, 5, 6, 7, 8, :gap, 30])
    end

    it 'leaves nothing out next to the last pages' do
      expect(page(count: 600, page: 29).series).to eq([1, :gap, 23, 24, 25, 26, 27, 28, '29', 30])
    end

    it 'shows a plain window when the bar is too narrow for the ends' do
      expect(page(count: 600, page: 12).series(size: 5)).to eq([10, 11, '12', 13, 14])
    end

    it 'always has as many entries as asked for, or one per page' do
      [[600, 10], [600, 7], [45, 10]].each do |count, size|
        (1..page(count: count).pages).each do |number|
          expect(page(count: count, page: number).series(size: size).size).to eq([size, page(count: count).pages].min)
        end
      end
    end
  end

  describe '#as_json' do
    it 'names the numbers, nothing of the object itself' do
      expect(page(count: 45, page: 2).as_json).to eq(
        count: 45, page: 2, limit: 20, pages: 3, last: 3, in: 20, offset: 20, prev: 1, next: 3, from: 21, to: 40
      )
    end

    # The saved views answered with the gem's object until 18.11.2026; a client
    # reading `last` or `in` there keeps its numbers.
    it 'keeps the names the gem gave the number of pages and the rows on the page' do
      expect(page(count: 45, page: 3).as_json).to include(last: 3, in: 5)
      expect(page(count: 0).as_json).to include(last: 1, in: 0)
      expect(page(count: 45, page: 9).as_json).to include(last: 3, in: 0)
    end
  end

  describe '.of' do
    let(:organisation) { create(:organisation) }

    before do
      ActsAsTenant.current_tenant = organisation
      7.times { |i| Tag.create!(name: format('tag-%02d', i), organisation: organisation) }
    end

    after { ActsAsTenant.current_tenant = nil }

    let(:scope) { Tag.where(organisation: organisation).order(:name) }

    it 'answers the page and the rows of that page, in the order of the relation' do
      current, rows = described_class.of(scope, page: '2', limit: 3)

      expect(current).to have_attributes(count: 7, page: 2, pages: 3)
      expect(rows.map(&:name)).to eq(%w[tag-03 tag-04 tag-05])
    end

    it 'shows every row once across the pages' do
      # One query per page is the point here, not an N+1.
      names = Prosopite.pause do
        (1..3).flat_map { |number| described_class.of(scope, page: number, limit: 3).last.map(&:name) }
      end

      expect(names).to eq(scope.map(&:name))
    end

    it 'answers a page behind the end with no rows and without an OFFSET query' do
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] }
      rows = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        described_class.of(scope, page: '9' * 30, limit: 3).last.to_a
      end

      expect(rows).to eq([])
      expect(queries.grep(/OFFSET/)).to be_empty
    end

    it 'answers the last page instead when the list asks for it' do
      _, rows = described_class.of(scope, page: 99, limit: 3, past_end: :last)

      expect(rows.map(&:name)).to eq(%w[tag-06])
    end

    it 'does not count when the caller knows the total' do
      allow(scope).to receive(:count).and_raise('counted')

      current, = described_class.of(scope, page: 1, limit: 3, count: 7)

      expect(current.count).to eq(7)
    end

    it 'counts the rows of a grouped relation, not the rows inside the groups' do
      grouped = Tag.where(organisation: organisation).group(:name).order(:name)

      current, = described_class.of(grouped, page: 1, limit: 3)

      expect(current.count).to eq(7)
    end
  end
end
