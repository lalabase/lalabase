# frozen_string_literal: true

namespace :docs do
  desc 'Refresh the catalogue fixture the help specs read from a generated example catalogue'
  task :catalogue_fixture, [:source_dir] => :environment do |_task, args|
    # The example catalogue holds two pages. This limit is what separates "an
    # example of the format" from "the handbook": the real one carries 42 pages
    # per language, and its text must not live in this repository at all,
    # because this repository is going open source (doc/docs_delivery_plan.md,
    # goal 1).
    #
    # A local, not a constant: inside `namespace` and `task` blocks a constant
    # lands on Object, and a .rake file gives only a Ruby warning for it.
    max_pages = 5

    source = args[:source_dir] || ENV.fetch('DOCS_CATALOGUE_PATH', nil)
    if source.nil?
      abort <<~MESSAGE
        Pass the directory an EXAMPLE catalogue was written to:

          # in the documentation repository
          DOCS_CATALOGUE_PATH=/tmp/example bin/rails catalogue:example
          # here
          bin/rails "docs:catalogue_fixture[/tmp/example]"

        Note `catalogue:example`, NOT `catalogue:write`: the second one writes the
        whole handbook, whose text must not live in this repository.

        The fixture is a catalogue the OTHER program really wrote, not one this
        repository builds itself. A rebuilt one would drift from the format that
        program writes, and the drift would look like passing specs.
      MESSAGE
    end

    files = Dir.glob(File.join(source, 'docs_catalogue.*.json')).sort
    abort "No docs_catalogue.*.json in #{source}" if files.empty?

    # Refuse the handbook rather than ask nicely. The fixture is checked in, so a
    # catalogue of the real pages would put the documentation text back into this
    # repository in JSON form, which is the mistake this limit exists to prevent
    # (found 2026-09-21, after it had already happened once).
    oversized = files.filter_map do |file|
      pages = JSON.parse(File.read(file))['pages'].to_a.size
      "#{File.basename(file)} has #{pages} pages" if pages > max_pages
    end

    unless oversized.empty?
      abort <<~MESSAGE
        Refusing to copy: #{oversized.join(', ')}.

        More than #{max_pages} pages means this is the handbook, not an example
        of the format. Run `catalogue:example` over there instead of
        `catalogue:write`.
      MESSAGE
    end

    target = Rails.root.join('spec/fixtures/docs_catalogue')
    files.each do |file|
      FileUtils.cp(file, target)
      puts "#{File.basename(file)} -> #{target} (#{File.size(file)} bytes)"
    end
  end
end
