# frozen_string_literal: true

require 'rails_helper'

# What: Documentation::AssetCollector, which copies the images a documentation set's
#       pages refer to out of the cloned repository.
# Type: Service spec, on a real directory.
# Why:  The repository is not ours. A page may name any path, a file may be a symlink to
#       anywhere on the worker's disk, and a file's name says nothing about its content.
#       What the collector accepts is served from OUR origin to everybody who may read
#       the documentation, so every refusal here is a security boundary, and each one is
#       pinned with the file that would cross it.
RSpec.describe Documentation::AssetCollector do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:set) { create(:documentation_set, project: project, path_prefix: 'docs/') }
  let(:repo) { Pathname.new(Dir.mktmpdir('asset-collector-spec-')) }
  let(:outside) { Pathname.new(Dir.mktmpdir('asset-collector-outside-')) }
  let(:png) { Rails.root.join('spec/fixtures/files/test_avatar.png').binread }
  let(:collector) { described_class.new(documentation_set: set, repo_path: repo) }

  before { ActsAsTenant.current_tenant = organisation }

  after do
    ActsAsTenant.current_tenant = nil
    FileUtils.remove_entry(repo, true)
    FileUtils.remove_entry(outside, true)
  end

  def write_file(relative, bytes, root: repo)
    full = root.join(relative)
    FileUtils.mkdir_p(full.dirname)
    File.binwrite(full, bytes)
    full
  end

  def asset_for(path)
    set.documentation_assets.find_by(path: path)
  end

  describe 'an image of the repository' do
    before { write_file('docs/img/logo.png', png) }

    it 'is stored once, with the type of its bytes, and answered with the address of the file proxy' do
      address = collector.address_for('docs/img/logo.png')
      asset = asset_for('docs/img/logo.png')

      expect(asset).to have_attributes(content_type: 'image/png', byte_size: png.bytesize, organisation: organisation)
      expect(asset.file.download).to eq(png)
      expect(address).to eq("/org/#{organisation.id}/files/documentation_asset/#{asset.id}")
      expect(collector).to have_attributes(synced: 1, skipped: 0)
    end

    it 'carries the blob SHA git itself would give the file' do
      collector.address_for('docs/img/logo.png')

      expected = Digest::SHA1.hexdigest("blob #{png.bytesize}\0".b + png)
      expect(asset_for('docs/img/logo.png').git_blob_sha).to eq(expected)
    end

    it 'is one row for two pages that show it' do
      first = collector.address_for('docs/img/logo.png')
      second = collector.address_for('docs/img/logo.png')

      expect(second).to eq(first)
      expect(set.documentation_assets.count).to eq(1)
      expect(collector.synced).to eq(1)
    end

    it 'keeps its row, its address and its upload on the next run when it did not change' do
      address = collector.address_for('docs/img/logo.png')
      blob_id = asset_for('docs/img/logo.png').file.blob.id

      again = described_class.new(documentation_set: set, repo_path: repo)

      expect(again.address_for('docs/img/logo.png')).to eq(address)
      expect(asset_for('docs/img/logo.png').file.blob.id).to eq(blob_id)
    end

    it 'keeps its row and its address and takes the new bytes when it changed' do
      address = collector.address_for('docs/img/logo.png')
      other = Rails.root.join('spec/fixtures/files/avatar_quadrants.png').binread
      write_file('docs/img/logo.png', other)

      again = described_class.new(documentation_set: set, repo_path: repo)

      expect(again.address_for('docs/img/logo.png')).to eq(address)
      expect(asset_for('docs/img/logo.png').file.download).to eq(other)
      expect(asset_for('docs/img/logo.png').byte_size).to eq(other.bytesize)
    end

    it 'may lie outside the documentation folder, as long as it is inside the repository' do
      write_file('assets/shared.png', png)

      expect(collector.address_for('assets/shared.png')).to be_present
    end
  end

  describe 'what is refused' do
    def refused(path)
      expect(collector.address_for(path)).to be_nil
      expect(set.documentation_assets.where(path: path)).to be_empty
    end

    it 'a file that is not there' do
      refused('docs/img/missing.png')
      expect(collector).to have_attributes(synced: 0, skipped: 1)
    end

    it 'a directory' do
      FileUtils.mkdir_p(repo.join('docs/img.png'))

      refused('docs/img.png')
    end

    it 'a page of HTML that calls itself .png' do
      write_file('docs/img/fake.png', '<html><script>alert(1)</script></html>')

      refused('docs/img/fake.png')
    end

    # Bytes that say nothing about their type: a guess from the NAME would call them a PNG.
    it 'bytes of no known type that call themselves .png' do
      write_file('docs/img/words.png', 'just some words, and not a single pixel')

      refused('docs/img/words.png')
    end

    it 'an SVG, whatever it is called' do
      svg = Rails.root.join('spec/fixtures/files/avatar_bomb.svg').binread
      write_file('docs/img/diagram.svg', svg)
      write_file('docs/img/diagram.png', svg)

      refused('docs/img/diagram.svg')
      refused('docs/img/diagram.png')
    end

    it 'a file one byte over the limit, and not one at the limit' do
      stub_const("#{described_class}::MAX_BYTES", png.bytesize)
      write_file('docs/img/exact.png', png)
      write_file('docs/img/over.png', "#{png}\0")

      expect(collector.address_for('docs/img/exact.png')).to be_present
      refused('docs/img/over.png')
    end

    it 'an empty file' do
      write_file('docs/img/empty.png', '')

      refused('docs/img/empty.png')
    end

    it 'the image after the last one the set may hold' do
      stub_const("#{described_class}::MAX_ASSETS", 2)
      %w[a b c].each { |name| write_file("docs/img/#{name}.png", png) }

      expect(collector.address_for('docs/img/a.png')).to be_present
      expect(collector.address_for('docs/img/b.png')).to be_present
      refused('docs/img/c.png')
      # An image already counted is not refused for being asked about again.
      expect(collector.address_for('docs/img/a.png')).to be_present
      expect(collector).to have_attributes(synced: 2, skipped: 1)
    end

    it 'a path that climbs out of the repository' do
      write_file('secret.png', png, root: outside)
      relative = outside.join('secret.png').relative_path_from(repo).to_s

      expect(relative).to start_with('..')
      refused(relative)
    end

    it 'an absolute path' do
      write_file('secret.png', png, root: outside)

      refused(outside.join('secret.png').to_s)
    end

    it 'a symlink to a file outside the repository, although it looks like an image inside it' do
      write_file('secret.png', png, root: outside)
      FileUtils.mkdir_p(repo.join('docs/img'))
      File.symlink(outside.join('secret.png'), repo.join('docs/img/innocent.png'))

      refused('docs/img/innocent.png')
    end

    it 'a file reached through a symlinked directory that leaves the repository' do
      write_file('pictures/secret.png', png, root: outside)
      FileUtils.mkdir_p(repo.join('docs'))
      File.symlink(outside.join('pictures'), repo.join('docs/img'))

      refused('docs/img/secret.png')
    end

    it 'nothing at all through a symlink that stays inside the repository' do
      write_file('assets/real.png', png)
      FileUtils.mkdir_p(repo.join('docs/img'))
      File.symlink(repo.join('assets/real.png'), repo.join('docs/img/alias.png'))

      expect(collector.address_for('docs/img/alias.png')).to be_present
    end
  end

  describe 'a failing storage' do
    it 'costs the image, not the run' do
      write_file('docs/img/logo.png', png)
      allow_any_instance_of(DocumentationAsset).to receive(:save!).and_raise(ActiveStorage::IntegrityError)

      expect(collector.address_for('docs/img/logo.png')).to be_nil
      expect(collector).to have_attributes(synced: 0, skipped: 1)
    end
  end

  describe '#finish' do
    it 'destroys the images of the set that no page asked about in this run, file and all' do
      write_file('docs/img/kept.png', png)
      write_file('docs/img/dropped.png', png)
      first = described_class.new(documentation_set: set, repo_path: repo)
      first.address_for('docs/img/kept.png')
      first.address_for('docs/img/dropped.png')
      first.finish
      dropped_blob = asset_for('docs/img/dropped.png').file.blob.id

      second = described_class.new(documentation_set: set, repo_path: repo)
      second.address_for('docs/img/kept.png')
      adapter_was = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      perform_enqueued_jobs { second.finish }
      ActiveJob::Base.queue_adapter = adapter_was

      expect(set.documentation_assets.pluck(:path)).to eq(['docs/img/kept.png'])
      expect(ActiveStorage::Blob.find_by(id: dropped_blob)).to be_nil
    end

    it 'leaves the images of another set alone' do
      other_set = create(:documentation_set, project: project)
      other = create(:documentation_asset, documentation_set: other_set)

      collector.finish

      expect(DocumentationAsset.find_by(id: other.id)).to be_present
    end
  end
end
