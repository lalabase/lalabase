# frozen_string_literal: true

require 'rails_helper'

# What: Documents::NumberVersions, the stock's version numbers (doc/dokumentansicht_plan.md, S1).
# Type: service spec on real records.
# Why: the number is the identifier one talks about, and it is right only if it
#   follows time. A document with any unnumbered version is counted afresh from 1
#   by created_at, ALL its versions, because a version the actor numbered against
#   no numbered sibling (between deploy and run) carries a 1 that is wrong. A fully
#   numbered document is left alone, another organisation is never touched, and a
#   second run changes nothing.
RSpec.describe Documents::NumberVersions do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  def document_with_versions(stamps:, org: organisation, proj: project)
    ActsAsTenant.with_tenant(org) do
      Prosopite.pause do
        doc = create(:document, project: proj, organisation: org, creator: user)
        versions = stamps.map do |created_at, number|
          create(:document_version, document: doc, organisation: org, number: number, created_at: created_at)
        end
        doc.update!(current_version: versions.last)
        [doc, versions]
      end
    end
  end

  # ONE query for the numbers, not a reload per version (Prosopite counts those).
  def numbers_of(versions)
    DocumentVersion.unscoped.where(id: versions.map(&:id)).order(:created_at, :id).pluck(:number)
  end

  it 'numbers an unnumbered document chronologically from 1' do
    _doc, (oldest, middle, newest) = document_with_versions(stamps: [[3.days.ago, nil], [2.days.ago, nil], [1.day.ago, nil]])

    result = described_class.call(organisation: organisation)

    expect(result.documents).to eq(1)
    expect(result.versions).to eq(3)
    expect(numbers_of([oldest, middle, newest])).to eq([1, 2, 3])
  end

  it 'counts a partly numbered document afresh, so the order follows time and not the upload date of the column' do
    # The actor gave the newest version a 1 against no numbered sibling.
    _doc, (oldest, middle, newest) = document_with_versions(stamps: [[3.days.ago, nil], [2.days.ago, nil], [1.day.ago, 1]])

    described_class.call(organisation: organisation)

    expect(numbers_of([oldest, middle, newest])).to eq([1, 2, 3])
  end

  it 'leaves a fully numbered document alone, and a second run changes nothing' do
    _doc, (first, second) = document_with_versions(stamps: [[2.days.ago, 1], [1.day.ago, 2]])

    result = described_class.call(organisation: organisation)
    expect(result.documents).to eq(0)
    expect(numbers_of([first, second])).to eq([1, 2])

    again = described_class.call(organisation: organisation)
    expect(again.documents).to eq(0)
  end

  it 'touches no document of another organisation' do
    other = create(:organisation)
    other_project = ActsAsTenant.with_tenant(other) { create(:project, organisation: other) }
    _doc, (foreign,) = document_with_versions(org: other, proj: other_project, stamps: [[1.day.ago, nil]])

    result = described_class.call(organisation: organisation)

    expect(result.documents).to eq(0)
    expect(foreign.reload.number).to be_nil
  end

  # Two writers touch a document's numbers: this task and the upload actor
  # (review of #779). The transaction alone leaves a window between the clear
  # and the count: the clear locks the rows that exist, not the one an upload
  # inserts meanwhile. That row carries a 1 against no numbered sibling, the
  # count hands the same 1 to the oldest stock row, and the unique index aborts
  # the run. Both writers take the document's row lock first, so the upload
  # waits for this commit and counts from the new maximum.
  it 'holds the document row lock before it touches a number' do
    document_with_versions(stamps: [[2.days.ago, nil], [1.day.ago, nil]])

    statements = capture_sql { described_class.call(organisation: organisation) }

    lock = statements.index { |sql| sql.match?(/FROM "documents".*FOR UPDATE/m) }
    first_write = statements.index { |sql| sql.match?(/UPDATE "?document_versions"?/) }
    expect(lock).not_to be_nil
    expect(lock).to be < first_write
  end
end
