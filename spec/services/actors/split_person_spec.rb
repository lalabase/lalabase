# frozen_string_literal: true

require 'rails_helper'

# What: Actors::SplitPerson, the write behind "Zusammenführung aufheben": the caller's own
#   group goes, with its entries. Another person's group and a missing one answer alike.
RSpec.describe Actors::SplitPerson, :ci_guard do
  include AllPeopleHelpers

  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }
  let(:viewer) { create(:user) }
  let(:other) { create(:user) }
  let!(:north_row) { person_in(north, name: 'Kai Kontakt') }
  let!(:south_row) { person_in(south, name: 'Kai Kontakt') }

  def group_of(owner)
    create(:person_group, owner: owner).tap do |group|
      create(:person_group_entry, person_group: group, organisation: north, person_id: north_row.id)
      create(:person_group_entry, person_group: group, organisation: south, person_id: south_row.id)
    end
  end

  def split(id, user: viewer)
    described_class.call(group_id: id, current_user: user)
  end

  let!(:mine) { group_of(viewer) }
  let!(:theirs) { group_of(other) }

  it 'deletes the group of the caller with its entries and leaves the rows alone' do
    result = nil

    expect { result = split(mine.id) }.to change(PersonGroupEntry, :count).from(4).to(2)

    expect(result).to be_success
    expect(result.resource).to eq(mine)
    expect(PersonGroup.pluck(:id)).to eq([theirs.id])
    expect(Person.unscoped.where(id: [north_row.id, south_row.id]).count).to eq(2)
    expect(ActsAsTenant.current_tenant).to be_nil
  end

  it 'answers the group of another owner, a missing one and a malformed id alike, and deletes nothing' do
    answers = [theirs.id, SecureRandom.uuid, 'oops', nil, 7].map do |id|
      result = nil
      Prosopite.pause { expect { result = split(id) }.not_to(change { [PersonGroup.count, PersonGroupEntry.count] }) }
      [result.success?, result.code, result.errors]
    end

    expect(answers.uniq).to eq([[false, :not_found, [I18n.t('controllers.people.not_found')]]])
  end

  # Two groups can join one row of the list: each names an entry of the same account in
  # another organisation, and the account rule shows those entries as one person. The row
  # carries the id of one group. With only that one gone, the row stood merged after "undo".
  describe 'a row that two merges join' do
    let(:west) { create(:organisation, name: 'West KG') }
    let(:east) { create(:organisation, name: 'Ost eG') }
    let(:shared) { create(:user, first_name: 'Mara', last_name: 'Mitglied') }
    let(:west_row) { person_in(west, name: 'M. Mitglied (West)') }
    let(:east_row) { person_in(east, name: 'M. Mitglied (Ost)') }

    before do
      Prosopite.pause do
        [north, south, west, east].each { |organisation| join_organisation(viewer, organisation, admin: true) }
        [north, south].each { |organisation| join_organisation(shared, organisation) }
      end
      PersonGroup.where(id: mine.id).delete_all
    end

    def list
      People::AcrossOrganisations.call(viewer: User.find(viewer.id)).rows
    end

    def group_naming(organisation, row_organisation, row)
      create(:person_group, owner: viewer).tap do |group|
        create(:person_group_entry, person_group: group, organisation: organisation, user_id: shared.id)
        create(:person_group_entry, person_group: group, organisation: row_organisation, person_id: row.id)
      end
    end

    it 'takes both apart, whichever of them the row names' do
      first = group_naming(north, west, west_row)
      second = group_naming(south, east, east_row)
      merged = list.select(&:merge_id)
      expect(merged.map { |row| row.sources.size }).to eq([4])
      expect([first.id, second.id]).to include(merged.first.merge_id)

      expect(split(merged.first.merge_id)).to be_success

      expect(list.filter_map(&:merge_id)).to be_empty
      expect(PersonGroup.where(owner_id: viewer.id)).not_to exist
    end

    it 'leaves a merge of another row alone' do
      first = group_naming(north, west, west_row)
      other = create(:person_group, owner: viewer)
      create(:person_group_entry, person_group: other, organisation: east, person_id: east_row.id)
      create(:person_group_entry, person_group: other, organisation: south, person_id: south_row.id)

      expect(split(first.id)).to be_success

      expect(PersonGroup.where(owner_id: viewer.id).pluck(:id)).to eq([other.id])
    end

    it 'refuses to detach a source that the account rule would still join to the others' do
      first = group_naming(north, west, west_row)
      group_naming(south, east, east_row)
      before = list
      result = nil

      expect { result = described_class.call(group_id: first.id, current_user: viewer, source: "#{north.id}:member:#{shared.id}") }
        .not_to(change { PersonGroupEntry.count })

      expect([result.success?, result.code]).to eq([false, :conflict])
      expect(list).to eq(before)
    end
  end

  # From the card of a merged person one source can leave alone (source:
  # "<organisation id>:<entry address>"): only the lines that name it go.
  describe 'taking one source out' do
    let(:west) { create(:organisation, name: 'West KG') }
    let(:west_row) { person_in(west, name: 'Kai Kontakt') }

    before do
      Prosopite.pause do
        [north, south, west].each { |organisation| join_organisation(viewer, organisation, admin: true) }
      end
    end

    def address(organisation, row)
      "#{organisation.id}:person:#{row.id}"
    end

    def take_out(source, id: mine.id, user: viewer)
      described_class.call(group_id: id, current_user: user, source: source)
    end

    # The rows called Kai Kontakt, each as the organisations it stands for (the viewer is
    # a row of the list as well, a member of all three).
    def list
      People::AcrossOrganisations.call(viewer: User.find(viewer.id)).rows
                                 .select { |row| row.name == 'Kai Kontakt' }.map { |row| row.sources.map(&:organisation_name) }
    end

    def entries(group)
      PersonGroupEntry.where(person_group_id: group.id).pluck(:organisation_id).sort
    end

    context 'with three sources' do
      before { create(:person_group_entry, person_group: mine, organisation: west, person_id: west_row.id) }

      it 'removes that source and leaves the others merged' do
        expect(list).to eq([['Nord GmbH', 'Sued AG', 'West KG']])

        result = take_out(address(south, south_row))

        expect(result).to be_success
        expect(result.resource).to eq(mine)
        expect(entries(mine)).to eq([north.id, west.id].sort)
        expect(list).to contain_exactly(['Nord GmbH', 'West KG'], ['Sued AG'])
        expect(entries(theirs).size).to eq(2)
        expect(Person.unscoped.where(id: [north_row.id, south_row.id, west_row.id]).count).to eq(3)
        expect(ActsAsTenant.current_tenant).to be_nil
      end

      it 'removes the first source just as well' do
        expect(take_out(address(north, north_row))).to be_success

        expect(list).to contain_exactly(['Sued AG', 'West KG'], ['Nord GmbH'])
      end

      it 'answers everything it cannot take out alike, and deletes nothing' do
        elsewhere = person_in(west, name: 'Wanda West')
        hidden = create(:organisation, name: 'Ost eG')
        hidden_row = person_in(hidden, name: 'Olga Ost')
        answers = [
          address(west, elsewhere),                  # a person the viewer sees, in no merge
          address(north, south_row),                 # a row under the wrong organisation
          address(hidden, hidden_row),               # an organisation that is not the viewer's
          "#{north.id}:person:#{SecureRandom.uuid}", "#{north.id}:person:oops", "#{north.id}:", 'oops', '', 7, [address(south, south_row)]
        ].map do |source|
          result = nil
          Prosopite.pause { expect { result = take_out(source) }.not_to(change { [PersonGroup.count, PersonGroupEntry.count] }) }
          [result.success?, result.code, result.errors]
        end

        expect(answers.uniq).to eq([[false, :not_found, [I18n.t('controllers.people.not_found')]]])
        # The same call takes out a source it can name.
        expect(take_out(address(south, south_row))).to be_success
      end

      it 'answers the group of another owner like a missing one, whatever source is named' do
        result = nil

        expect { result = take_out(address(south, south_row), id: theirs.id) }.not_to(change { PersonGroupEntry.count })

        expect([result.success?, result.code]).to eq([false, :not_found])
      end

      it 'does not take out a source the viewer may no longer read' do
        Prosopite.pause { take_people_right(viewer, south) }
        result = nil

        expect { result = take_out(address(south, south_row)) }.not_to(change { PersonGroupEntry.count })

        expect([result.success?, result.code]).to eq([false, :not_found])
      end

      it 'leaves a merge of another person of the viewer alone' do
        other_north = person_in(north, name: 'Nora Nord')
        other_south = person_in(south, name: 'Nora Nord')
        second = create(:person_group, owner: viewer)
        create(:person_group_entry, person_group: second, organisation: north, person_id: other_north.id)
        create(:person_group_entry, person_group: second, organisation: south, person_id: other_south.id)

        # A source of the second merge is no source of the first.
        refused = take_out(address(south, other_south))
        expect([refused.success?, refused.code]).to eq([false, :not_found])
        expect(take_out(address(south, south_row))).to be_success

        expect(entries(second).size).to eq(2)
      end
    end

    # A member is stored by the row when they have one and by the account while they have
    # none; a line written before the row existed still names the account. The source is
    # addressed by the account either way ("member:<id>"), and by the row as well.
    describe 'a source that is a member' do
      let(:member) { create(:user, first_name: 'Mara', last_name: 'Mitglied') }

      before do
        Prosopite.pause { join_organisation(member, north) }
        create(:person_group_entry, person_group: mine, organisation: west, person_id: west_row.id)
        PersonGroupEntry.where(person_group_id: mine.id, organisation_id: north.id).delete_all
      end

      def member_address
        "#{north.id}:member:#{member.id}"
      end

      def expect_member_taken_out(source)
        result = nil
        expect { result = take_out(source) }.to change { PersonGroupEntry.where(person_group_id: mine.id).count }.from(3).to(2)

        expect(result).to be_success
        expect(entries(mine)).to eq([south.id, west.id].sort)
        expect(entries(theirs).size).to eq(2)
      end

      it 'takes out a member without a row, stored by the account' do
        create(:person_group_entry, person_group: mine, organisation: north, user_id: member.id)

        expect_member_taken_out(member_address)
      end

      it 'takes out a member stored by their row, named by the account or by the row' do
        row = person_in(north, user: member, name: 'Mara Mitglied')
        create(:person_group_entry, person_group: mine, organisation: north, person_id: row.id)

        expect_member_taken_out(member_address)

        create(:person_group_entry, person_group: mine, organisation: north, person_id: row.id)
        expect_member_taken_out("#{north.id}:person:#{row.id}")
      end

      it 'takes out a member whose line still names the account although they have a row by now' do
        person_in(north, user: member, name: 'Mara Mitglied')
        create(:person_group_entry, person_group: mine, organisation: north, user_id: member.id)

        expect_member_taken_out(member_address)
      end

      it 'takes out nothing of another account' do
        create(:person_group_entry, person_group: mine, organisation: north, user_id: member.id)
        stranger = create(:user)
        Prosopite.pause { join_organisation(stranger, north) }
        result = nil

        expect { result = take_out("#{north.id}:member:#{stranger.id}") }.not_to(change { PersonGroupEntry.count })

        expect([result.success?, result.code]).to eq([false, :not_found])
      end
    end

    it 'dissolves a merge of two when one of them is taken out' do
      result = take_out(address(south, south_row))

      expect(result).to be_success
      expect(PersonGroup.where(id: mine.id)).not_to exist
      expect(PersonGroupEntry.where(owner_id: viewer.id)).not_to exist
      expect(list).to contain_exactly(['Nord GmbH'], ['Sued AG'])
      expect(PersonGroup.where(id: theirs.id)).to exist
    end
  end

  # The card no longer offers this step (People::MergedCard, #shown_at's detachable): the
  # same grouping, done in memory, sees R come in. A request that sends it all the same
  # (an old card, a hand-made form) is refused by the actor and changes nothing.
  it 'rolls back taking a source out if a competing merge would replace another source' do
    Prosopite.pause do
      shared = create(:user)
      a, b, c, d = %w[A B C D].map { |name| create(:organisation, name: name) }
      [a, b, c, d].each { |organisation| join_organisation(viewer, organisation, admin: true) }
      [b, c].each { |organisation| join_organisation(shared, organisation) }
      first = person_in(a, name: 'X')
      kept = person_in(d, name: 'N', notes: 'Notes of N')
      competing = person_in(d, name: 'R', notes: 'Notes of R')
      winner = create(:person_group, owner: viewer)
      loser = create(:person_group, owner: viewer)
      [[winner, a, { person_id: first.id }], [winner, c, { user_id: shared.id }], [winner, d, { person_id: kept.id }],
       [loser, b, { user_id: shared.id }], [loser, d, { person_id: competing.id }]].each do |group, organisation, address|
        create(:person_group_entry, person_group: group, organisation: organisation, **address)
      end
      address = "#{b.id}:member:#{shared.id}"
      card = -> { People::MergedCard.call(viewer: User.find(viewer.id), address: address) }
      before = card.call
      expect(before.sources.map(&:name)).to include('X', 'N')
      expect(before.sources.map(&:name)).not_to include('R')
      expect(before.sources.find { |source| source.name == 'X' }.detachable).to be(false)
      stored = -> { PersonGroupEntry.order(:id).pluck(*PersonGroupEntry.column_names) }

      result = nil
      expect { result = described_class.call(group_id: winner.id, current_user: viewer, source: "#{a.id}:person:#{first.id}") }
        .not_to(change(&stored))

      expect([result.success?, result.code]).to eq([false, :conflict])
      expect(result.errors).to eq([I18n.t('controllers.people.split.conflict')])
      expect(card.call).to eq(before)
      expect(ActsAsTenant.current_tenant).to be_nil
    end
  end

  it 'deletes the caller\'s groups left with fewer than two entries on the way' do
    leftover = create(:person_group, owner: viewer)
    foreign_leftover = create(:person_group, owner: other)

    split(mine.id)

    expect(PersonGroup.where(id: leftover.id)).not_to exist
    expect(PersonGroup.where(id: foreign_leftover.id)).to exist
  end

  # The card and the write answer the same question with the same rule: for a person of
  # more than two parts, every source the card offers to take out is taken out, and every
  # other one is refused. Until the review of #197 the card asked only whether the source
  # stood alone in its account, and offered steps the actor always refused.
  describe 'the card offers exactly what it takes out' do
    def answers_for(address)
      card = People::MergedCard.call(viewer: User.find(viewer.id), address: address)
      card.sources.map do |source|
        taken = nil
        ActiveRecord::Base.transaction(requires_new: true) do
          taken = described_class.call(group_id: card.merge_id, current_user: User.find(viewer.id),
                                       source: People::MergedCard.address_of(source.organisation_id, source.address)).success?
          raise ActiveRecord::Rollback
        end
        [source.name, source.detachable, taken]
      end
    end

    it 'agrees for a merge that a competing merge holds in place' do
      address = nil
      Prosopite.pause do
        shared = create(:user, first_name: 'Sam', last_name: 'Shared')
        a, b, c, d = %w[A B C D].map { |name| create(:organisation, name: name) }
        [a, b, c, d].each { |organisation| join_organisation(viewer, organisation, admin: true) }
        [b, c].each { |organisation| join_organisation(shared, organisation) }
        first = person_in(a, name: 'X')
        kept = person_in(d, name: 'N')
        competing = person_in(d, name: 'R')
        winner = create(:person_group, owner: viewer)
        loser = create(:person_group, owner: viewer)
        [[winner, a, { person_id: first.id }], [winner, c, { user_id: shared.id }], [winner, d, { person_id: kept.id }],
         [loser, b, { user_id: shared.id }], [loser, d, { person_id: competing.id }]].each do |group, organisation, line|
          create(:person_group_entry, person_group: group, organisation: organisation, **line)
        end
        address = "#{b.id}:member:#{shared.id}"
      end

      answers = Prosopite.pause { answers_for(address) }

      expect(answers.map(&:first)).to eq(['X', 'Sam Shared', 'Sam Shared', 'N'])
      expect(answers.map { |_name, offered, taken| offered == taken }).to all(be(true))
    end

    it 'agrees for three sources a single merge joins, all of which can leave' do
      west = create(:organisation, name: 'West KG')
      Prosopite.pause do
        [north, south, west].each { |organisation| join_organisation(viewer, organisation, admin: true) }
        create(:person_group_entry, person_group: mine, organisation: west, person_id: person_in(west, name: 'Kai Kontakt').id)
      end

      answers = Prosopite.pause { answers_for("#{north.id}:person:#{north_row.id}") }

      expect(answers.map { |_name, offered, taken| [offered, taken] }).to eq([[true, true]] * 3)
    end
  end
end
