# frozen_string_literal: true

# Copies the images that the pages of a documentation set refer to out of the cloned
# repository into the instance, so that a reader's browser asks the instance for them
# and not the repository host.
#
# One collector per sync run. The renderer asks it for every relative image it meets;
# the job calls #finish after the last page.
#
# Entry point: address_for
#
# The repository is not ours. Everything accepted here is served from our own origin to
# everybody who may read the documentation, so an image is taken only if it
#   * lies inside the clone AFTER symlinks are resolved (a link to /etc/hosts is a file
#     "inside" the repository until it is followed),
#   * is a regular, non-empty file of at most MAX_BYTES,
#   * IS an image by its bytes, of a type on the one list of images the application
#     shows inline (RichTextEmbeds::IMAGE_CONTENT_TYPES). The name does not count, and
#     SVG is not on the list: it can carry script.
# and as long as the set holds fewer than MAX_ASSETS.
#
# A refusal is not an error. The page shows the image's alt text instead, and the run
# counts it (#skipped). The same goes for a storage that fails: the pages are the
# product, an image must not cost the run.
module Documentation
  class AssetCollector
    MAX_BYTES = 5.megabytes
    MAX_ASSETS = 200
    CONTENT_TYPES = RichTextEmbeds::IMAGE_CONTENT_TYPES

    PROXY_KIND = 'documentation_asset'

    def initialize(documentation_set:, repo_path:)
      @set = documentation_set
      @root = Pathname.new(repo_path).realpath
      @addresses = {}
      @existing = nil
    end

    # The address of the image at this path of the repository, or nil when it is not
    # served. Asked once per image and page; answered from memory after the first time.
    def address_for(repo_relative)
      path = repo_relative.to_s
      return @addresses[path] if @addresses.key?(path)

      @addresses[path] = store(path)
    end

    def synced
      @addresses.values.count(&:present?)
    end

    def skipped
      @addresses.values.count(&:nil?)
    end

    # Destroys the images of the set that no page asked about in this run. Called after
    # the pages were rendered and saved, so no saved page points at what goes here.
    def finish
      kept = @addresses.select { |_, address| address }.keys
      @set.documentation_assets.where.not(path: kept).find_each(&:destroy!)
    end

    private

    def store(path)
      file = file_inside_the_clone(path)
      return nil unless file

      bytes = file.binread
      content_type = Marcel::MimeType.for(StringIO.new(bytes))
      return nil unless CONTENT_TYPES.include?(content_type)

      asset = existing[path]
      return nil if asset.nil? && kept_count >= MAX_ASSETS

      proxy_address(upsert(asset, path, bytes, content_type))
    rescue StandardError => e
      Rails.logger.warn("Documentation::AssetCollector: skipped '#{path}' of set #{@set.id} — #{e.class}: #{e.message}")
      nil
    end

    # The file the path names, or nil. realpath follows every symlink on the way and
    # raises for a path that does not exist.
    def file_inside_the_clone(path)
      return nil if path.blank? || path.start_with?('/')

      file = @root.join(path).realpath
      return nil unless file.to_s.start_with?("#{@root}/")
      return nil unless file.file?
      return nil unless file.size.between?(1, MAX_BYTES)

      file
    rescue SystemCallError
      nil
    end

    def upsert(asset, path, bytes, content_type)
      sha = GitBlob.sha(bytes)
      asset ||= DocumentationAsset.new(documentation_set: @set, organisation: @set.organisation, path: path)
      return asset if asset.persisted? && asset.git_blob_sha == sha && asset.file.attached?

      asset.assign_attributes(git_blob_sha: sha, content_type: content_type, byte_size: bytes.bytesize)
      # identify: false, because the type was just read from the bytes: Rails would
      # otherwise guess again, and from the file name too.
      asset.file.attach(io: StringIO.new(bytes), filename: File.basename(path), content_type: content_type, identify: false)
      asset.save!
      existing[path] = asset
    end

    # The set's images as they are before this run, read once.
    def existing
      @existing ||= @set.documentation_assets.with_attached_file.index_by(&:path)
    end

    def kept_count
      @addresses.values.count(&:present?)
    end

    def proxy_address(asset)
      Rails.application.routes.url_helpers.organisation_file_download_path(
        organisation_id: @set.organisation_id, kind: PROXY_KIND, id: asset.id
      )
    end
  end
end
