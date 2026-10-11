# frozen_string_literal: true

module Documentation
  # Builds a nested folder → page tree from a flat list of DocumentationPage
  # records (paths like "guide/advanced/x.md"). Groups by path segments into
  # lightweight structs, stamping active + "changed since last visit" (DT5)
  # flags. The technique came from this application's own documentation
  # navigation, which left with D5; it lives on in
  # gboyke/lalabase-documentation.
  class Navigation
    DirNode = Struct.new(:label, :children, keyword_init: true) do
      def dir?
        true
      end
    end

    PageNode = Struct.new(:label, :page, :active, :changed, keyword_init: true) do
      def dir?
        false
      end
    end

    # pages: DocumentationPage collection (already scoped to present pages).
    # current_page_path: the path of the selected page, for the active flag.
    # changed_paths: set of page paths changed since the user's last visit.
    def initialize(pages, current_page_path: nil, changed_paths: [])
      @pages = pages.to_a
      @current_page_path = current_page_path
      @changed_paths = changed_paths.to_set
    end

    def nodes
      build_nodes(build_raw_tree)
    end

    private

    def build_raw_tree
      root = empty_dir
      @pages.sort_by(&:path).each do |page|
        *dirs, _file = page.path.split('/')
        cursor = root
        dirs.each do |dir|
          cursor[:dirs][dir] ||= empty_dir
          cursor = cursor[:dirs][dir]
        end
        cursor[:pages] << page
      end
      root
    end

    def empty_dir
      { dirs: {}, pages: [] }
    end

    # Folders first (alphabetical), then pages (by path order preserved).
    def build_nodes(dir_hash)
      dir_nodes = dir_hash[:dirs].sort_by(&:first).map do |name, subtree|
        DirNode.new(label: Naming.humanize(name), children: build_nodes(subtree))
      end

      page_nodes = dir_hash[:pages].map do |page|
        PageNode.new(
          # The sync job always stores a title, so the fallback is defensive only.
          label: page.title.presence || Naming.humanize(File.basename(page.path, '.*')),
          page: page,
          active: page.path == @current_page_path,
          changed: @changed_paths.include?(page.path)
        )
      end

      dir_nodes + page_nodes
    end
  end
end
