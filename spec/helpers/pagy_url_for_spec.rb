# frozen_string_literal: true

require 'rails_helper'

# The pagination URL builder, pinned on the two ways it was broken.
#
# These are the FIRST tests this builder has ever had. Until now
# config/initializers/pagy.rb replaced Pagy::Frontend with a stub in the test
# environment whose pagy_url_for answered '#', so nothing in the suite could
# have caught either defect: not the 500 on a page without route-defining
# params, and not the parameters lost on every page change.
RSpec.describe ApplicationHelper, type: :helper do
  def url(page, path: '/admin/accounts', query: {}, format: nil)
    helper.request.path_info = path
    helper.request.query_parameters.replace(query.stringify_keys)
    helper.request.path_parameters = helper.request.path_parameters.merge(format: format)
    helper.pagy_url_for(nil, page)
  end

  it 'builds a link from the request path, not from url_for' do
    # url_for could not answer for a page whose params define no route, which is
    # what raised "arguments passed to url_for can't be handled" -- a 500 on the
    # FIRST page of /admin/accounts as soon as a second page existed.
    expect(url(2)).to eq('/admin/accounts?page=2')
  end

  it 'keeps a query parameter the old allowlist did not know' do
    # `on` is the reference date the whole billing list is about. It was not in
    # the nine-entry permit list, so changing page silently reset the page to
    # today -- the operator saw different numbers without touching the date.
    expect(url(3, path: '/admin/billing_lists', query: { on: '2026-08-01' }))
      .to eq('/admin/billing_lists?on=2026-08-01&page=3')
  end

  it 'keeps a search term across the page change' do
    expect(url(2, query: { search: 'Muster GmbH' }))
      .to eq('/admin/accounts?page=2&search=Muster+GmbH')
  end

  it 'replaces an existing page rather than appending a second one' do
    expect(url(4, query: { page: '2', search: 'x' }))
      .to eq('/admin/accounts?page=4&search=x')
  end

  describe 'the format suffix' do
    # A pagination link points at the same screen one page further, never at
    # another representation of it. These two cases moved here from the deleted
    # Pageable#pagy_url_for, whose regex stripped a trailing UUID; asking routing
    # for the format covers that case AND every real format.
    it 'does not point at another representation of the page' do
      expect(url(2, path: '/tickets.turbo_stream', format: 'turbo_stream'))
        .to eq('/tickets?page=2')
    end

    it 'strips a UUID that routing parsed as the format' do
      uuid = 'd2ddf7cf-4a48-43ab-9d4c-ea3a4009c55f'

      expect(url(2, path: "/tickets.#{uuid}", format: uuid)).to eq('/tickets?page=2')
    end

    it 'leaves a dot alone that is part of the path, not the format' do
      expect(url(2, path: '/files/report.2026', format: nil))
        .to eq('/files/report.2026?page=2')
    end
  end

  it 'drops the parameters that must never travel in a link' do
    # format would make every pagination link ask for the same format as the
    # current response, authenticity_token would leak a CSRF token into a URL.
    built = url(2, query: { format: 'turbo_stream', authenticity_token: 'secret', search: 'x' })

    expect(built).to eq('/admin/accounts?page=2&search=x')
    expect(built).not_to include('secret')
  end
  # The other half of the same rule, and the half that fails silently. A dropped
  # CONTROL parameter is a broken link somebody notices; a dropped FILTER is
  # page 2 answering a different question than page 1, with no error anywhere.
  #
  # ticket_id was in the drop list until 31.08.2026. It went unnoticed while the
  # time list's frame did not advance the address; once it did, paging away from
  # a ticket-filtered list left an address without the filter, and that list's
  # pills rebuild from the address.
  it 'carries every filter the request came with' do
    built = url(2, query: { ticket_id: 'abc', project_id: 'p1', date_range: 'year', search: 'x' })

    expect(built).to include('ticket_id=abc')
    expect(built).to include('project_id=p1')
    expect(built).to include('date_range=year')
    expect(built).to include('search=x')
  end

  # Whatever the app grows next, it travels: the list names what must NOT, and
  # anything absent from it is a filter until somebody says otherwise.
  it 'carries a filter nobody has thought of yet' do
    expect(url(2, query: { some_future_filter: 'yes' })).to include('some_future_filter=yes')
  end

  # ticket_id, note_id and document_id are ONE kind of parameter: the open pane
  # on a list (layout_toggle_controller names exactly these three). Two of them
  # always travelled through pagination and ticket_id alone did not, so the
  # ticket list closed its pane on a page change while the notes and documents
  # lists kept theirs open. The inconsistency was the accident, not the rule.
  #
  # Pinned as a DECISION, because it is a behaviour change outside the screen
  # that prompted it: on the time list ticket_id is a filter, and dropping it
  # there lost the filter silently once that frame started advancing the address.
  it 'treats the three pane parameters alike' do
    built = url(2, query: { ticket_id: 't1', note_id: 'n1', document_id: 'd1' })

    expect(built).to include('ticket_id=t1')
    expect(built).to include('note_id=n1')
    expect(built).to include('document_id=d1')
  end
end
