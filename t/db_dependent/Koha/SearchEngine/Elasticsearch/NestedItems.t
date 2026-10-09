#!/usr/bin/perl

# Copyright 2026 Xercode
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

# End-to-end tests for the nested items channel (Bug XXXXX) against a live
# Elasticsearch server. They build the query with build_query_compat exactly as
# the search controllers do and run it against a throwaway index ("mydb", never
# the real biblios index), so they exercise the real same-item nested
# behaviour: the aggregation/filter combination that the unit tests can only
# check structurally.

use Modern::Perl;

use Test::More;
use Test::MockModule;
use JSON;

use t::lib::Mocks;
use t::lib::TestBuilder;

use Koha::SearchEngine::Elasticsearch::QueryBuilder;
use Koha::SearchEngine::Elasticsearch::Indexer;
use Koha::SearchEngine::Elasticsearch::Search;

my $index = 'mydb';

# Mirror the production injection: the throwaway index carries the nested
# items object plus the record-level items_count, without touching the real
# biblios mapping.
my $se = Test::MockModule->new('Koha::SearchEngine::Elasticsearch');
$se->mock(
    'get_elasticsearch_mappings',
    sub {
        my ($self) = @_;
        $self->sort_fields( {} );
        return {
            properties => {
                title                => { type => 'text' },
                'local-number__sort' => { type => 'integer' },
                items_count          => { type => 'integer' },
                items                => {
                    type       => 'nested',
                    properties => {
                        itemnumber                    => { type => 'integer' },
                        homebranch                    => { type => 'keyword' },
                        holdingbranch                 => { type => 'keyword' },
                        available                     => { type => 'boolean' },
                        available_for_patron          => { type => 'boolean' },
                        onrequest                     => { type => 'boolean' },
                        lost                          => { type => 'keyword' },
                        hidden_in_opac_custom         => { type => 'boolean' },
                        hidden_in_opac_by_preferences => { type => 'boolean' },
                        barcode                       => { type => 'keyword' },
                        itype                         => { type => 'keyword' },
                        callnumber                    => { type => 'keyword' },
                        dateaccessioned               => { type => 'date' },
                    },
                },
            },
        };
    }
);

my $builder  = Koha::SearchEngine::Elasticsearch::QueryBuilder->new( { index => $index } );
my $searcher = Koha::SearchEngine::Elasticsearch::Search->new( { index => $index } );

eval { $builder->get_elasticsearch_params; };
plan skip_all => 'Elasticsearch configuration not available' if $@;

my $indexer = Koha::SearchEngine::Elasticsearch::Indexer->new( { index => $index } );
eval { $indexer->drop_index; };
$indexer->create_index;

my $es = $searcher->get_elasticsearch;

# An item with all the boolean/keyword fields defaulted to "visible/available".
sub item {
    my (%override) = @_;
    return {
        homebranch                    => 'AAA',
        holdingbranch                 => 'AAA',
        available                     => JSON::true,
        available_for_patron          => JSON::true,
        onrequest                     => JSON::false,
        lost                          => '0',
        hidden_in_opac_custom         => JSON::false,
        hidden_in_opac_by_preferences => JSON::false,
        itype                         => 'BK',
        dateaccessioned               => '2000-01-01',
        %override,
    };
}

# title is the same for every record so a "*" query matches them all; the nested
# item filters are what must narrow the result set.
my %docs = (
    1 => {
        title       => 'river',
        items_count => 2,
        items       => [

            # available copy in AAA, and a different unavailable copy in BBB that
            # is on request. The two copies carry distinct barcode / itype /
            # acquisition date so the operand-routing tests can tell them apart.
            item(
                itemnumber => 11,
                homebranch => 'AAA',   holdingbranch => 'AAA', available       => JSON::true, onrequest => JSON::false,
                barcode    => 'BC-A1', itype         => 'BK',  dateaccessioned => '2020-06-01'
            ),
            item(
                itemnumber => 12,
                homebranch => 'BBB', holdingbranch => 'BBB', available => JSON::false, onrequest => JSON::true,
                available_for_patron => JSON::false,
                barcode              => 'BC-B1', itype => 'CD', dateaccessioned => '2019-06-01'
            ),
        ],
    },
    2 => {
        title       => 'river',
        items_count => 1,
        items       => [
            item(
                itemnumber => 21,
                homebranch => 'BBB',  holdingbranch => 'BBB', available       => JSON::true,
                barcode    => 'BC-2', itype         => 'BK',  dateaccessioned => '2021-06-01'
            )
        ],
    },
    3 => {
        title       => 'river',
        items_count => 0,
        items       => [],
    },
    4 => {
        title       => 'river',
        items_count => 1,
        items       => [
            item( itemnumber => 41, homebranch => 'CCC', holdingbranch => 'CCC', hidden_in_opac_custom => JSON::true )
        ],
    },
    5 => {
        title       => 'river',
        items_count => 1,
        items       => [
            item(
                itemnumber                    => 51, homebranch => 'CCC', holdingbranch => 'CCC',
                hidden_in_opac_by_preferences => JSON::true
            )
        ],
    },
);

for my $id ( sort keys %docs ) {
    $es->index( index => $searcher->index_name, id => $id, body => $docs{$id} );
}
$es->indices->refresh( index => $searcher->index_name );

# Build the query the same way the controllers do and return the matching record
# ids, sorted numerically.
sub matching_ids {
    my ( $limits, $params ) = @_;

    # skip_facets: these tests exercise the nested filter channel, not the
    # aggregations, and the throwaway mapping has no facet fields.
    my %p = ( skip_facets => 1, %{ $params // {} } );
    my ( undef, $query ) =
        $builder->build_query_compat( undef, ['*'], undef, $limits, undef, undef, undef, \%p );
    my $results = $searcher->search( $query, undef, 50 );
    return [ sort { $a <=> $b } map { $_->{_id} } @{ $results->{hits}{hits} } ];
}

# Like matching_ids but driving the operand/index channel (the advanced-search
# "Search for" rows), so the item operands are routed to the nested filter.
sub matching_ids_search {
    my ( $operators, $operands, $indexes, $limits, $params ) = @_;
    my %p = ( skip_facets => 1, %{ $params // {} } );
    my ( undef, $query ) =
        $builder->build_query_compat( $operators, $operands, $indexes, $limits, undef, undef, undef, \%p );
    my $results = $searcher->search( $query, undef, 50 );
    return [ sort { $a <=> $b } map { $_->{_id} } @{ $results->{hits}{hits} } ];
}

# Build the query with want_matched_items and, for each returned record, extract
# the itemnumbers ES reports as matching via inner_hits. Returns a map
# record id => sorted arrayref of matched itemnumbers (or undef if not filtered).
sub matched_map {
    my ( $limits, $params ) = @_;
    my %p = ( skip_facets => 1, want_matched_items => 1, %{ $params // {} } );
    my ( undef, $query ) =
        $builder->build_query_compat( undef, ['*'], undef, $limits, undef, undef, undef, \%p );
    my $results = $searcher->search( $query, undef, 50 );
    my %by_id;
    for my $hit ( @{ $results->{hits}{hits} } ) {
        my $nums = $searcher->matched_itemnumbers($hit);
        $by_id{ $hit->{_id} } = defined $nums ? [ sort { $a <=> $b } @$nums ] : undef;
    }
    return \%by_id;
}

subtest 'inner_hits reports the matching items (Bug XXXXX)' => sub {
    plan tests => 6;

    # Same-item filter: only record 1's AAA copy (11) matches, not its BBB copy (12).
    my $by_id = matched_map( [ 'items.available:true', 'items.homebranch:AAA' ] );
    is_deeply( [ sort keys %$by_id ], [1],  'only record 1 matches the same-item filter' );
    is_deeply( $by_id->{1},           [11], 'inner_hits reports just the matching AAA copy, not the BBB copy' );

    # homebranch:BBB (intranet) matches records 1 and 2, each reporting only its
    # own BBB copy -- record 1 reports item 12 (its BBB copy), not item 11.
    $by_id = matched_map( ['items.homebranch:BBB'] );
    is_deeply( [ sort keys %$by_id ], [ 1, 2 ], 'homebranch:BBB matches records 1 and 2' );
    is_deeply( $by_id->{1},           [12],     'record 1 reports only its BBB copy (12), not its AAA copy' );
    is_deeply( $by_id->{2},           [21],     'record 2 reports its BBB copy (21)' );

    # Without want_matched_items there is no inner_hits, so matched_itemnumbers is
    # undef (the caller must not filter).
    my ( undef, $query ) = $builder->build_query_compat(
        undef, ['*'], undef, ['items.homebranch:AAA'], undef, undef, undef,
        { skip_facets => 1 }
    );
    my $results = $searcher->search( $query, undef, 50 );
    my ($hit) = grep { $_->{_id} == 1 } @{ $results->{hits}{hits} };
    is( $searcher->matched_itemnumbers($hit), undef, 'no inner_hits without want_matched_items => undef' );
};

subtest 'same-item availability + library' => sub {
    plan tests => 4;

    is_deeply(
        matching_ids( [ 'items.available:true', 'items.homebranch:AAA' ] ),
        [1],
        'available in AAA matches only the record whose AAA copy is available'
    );

    # The discriminating case: record 1 has a BBB copy (not available) and an
    # available AAA copy. A flat cross-item query would wrongly return it; the
    # nested same-item filter must not.
    is_deeply(
        matching_ids( [ 'items.available:true', 'items.homebranch:BBB' ] ),
        [2],
        'available in BBB matches only the record whose BBB copy is available (not record 1)'
    );

    is_deeply(
        matching_ids( ['items.available:true'] ),
        [ 1, 2, 4, 5 ],
        'available alone matches every record with at least one available copy'
    );

    is_deeply(
        matching_ids( ['items.homebranch:AAA'] ),
        [1],
        'library alone matches the record holding a copy in that library'
    );
};

subtest 'same-item patron availability + library' => sub {
    plan tests => 3;

    is_deeply(
        matching_ids( [ 'items.available_for_patron:true', 'items.homebranch:AAA' ] ),
        [1],
        'patron-available in AAA matches only the record whose AAA copy is patron-available'
    );

    # Same-item killer: record 1's BBB copy is NOT patron-available, record 2's
    # BBB copy is. A flat cross-item query would wrongly return record 1 too.
    is_deeply(
        matching_ids( [ 'items.available_for_patron:true', 'items.homebranch:BBB' ] ),
        [2],
        'patron-available in BBB matches only record 2 (record 1 BBB copy is blocked)'
    );

    is_deeply(
        matching_ids( ['items.available_for_patron:true'] ),
        [ 1, 2, 4, 5 ],
        'patron-available alone matches every record with a patron-available copy'
    );
};

subtest 'on-request filter (R10)' => sub {
    plan tests => 2;

    is_deeply(
        matching_ids( ['items.onrequest:true'] ),
        [1],
        'onrequest:true matches only the record with a requested copy'
    );

    is_deeply(
        matching_ids( ['items.onrequest:false'] ),
        [ 1, 2, 4, 5 ],
        'onrequest:false matches every record with a non-requested copy'
    );
};

subtest 'OPAC item hiding' => sub {
    plan tests => 3;

    # In the OPAC the hidden copies must not satisfy a same-item filter.
    is_deeply(
        matching_ids( ['items.homebranch:CCC'], { is_opac => 1 } ),
        [],
        'OPAC hides both custom- and preference-hidden copies'
    );

    # A patron whose category overrides hidden items sees the preference-hidden
    # copy (record 5) but never the custom-hidden one (record 4).
    is_deeply(
        matching_ids( ['items.homebranch:CCC'], { is_opac => 1, override_hidden_items => 1 } ),
        [5],
        'override lifts preference hiding but not custom hiding'
    );

    # The intranet sees every copy.
    is_deeply(
        matching_ids( ['items.homebranch:CCC'] ),
        [ 4, 5 ],
        'intranet does not hide any copy'
    );
};

subtest 'record suppression without user filters' => sub {
    plan tests => 3;

    t::lib::Mocks::mock_preference( 'OpacHiddenItemsHidesRecord', 1 );
    is_deeply(
        matching_ids( [], { is_opac => 1 } ),
        [ 1, 2, 3 ],
        'OPAC with H on: item-less record shown, all-hidden records suppressed'
    );

    t::lib::Mocks::mock_preference( 'OpacHiddenItemsHidesRecord', 0 );
    is_deeply(
        matching_ids( [], { is_opac => 1 } ),
        [ 1, 2, 3, 4, 5 ],
        'OPAC with H off: no record is suppressed'
    );

    is_deeply(
        matching_ids( [] ),
        [ 1, 2, 3, 4, 5 ],
        'intranet: no record is suppressed'
    );
};

subtest 'library limit routed to the nested channel' => sub {
    plan tests => 3;

    t::lib::Mocks::mock_preference( 'SearchLimitLibrary', 'homebranch' );

    is_deeply(
        matching_ids( ['branch:BBB'] ),
        [ 1, 2 ],
        'branch: limit matches every record with a copy in that library'
    );

    # Same-item: record 1 has a BBB copy but it is not available, so combining
    # branch:BBB with availability must not return it.
    is_deeply(
        matching_ids( [ 'branch:BBB', 'items.available:true' ] ),
        [2],
        'branch: limit resolves on the same item as the availability filter'
    );

    # "both" matches either the home or the holding branch of a single item.
    t::lib::Mocks::mock_preference( 'SearchLimitLibrary', 'both' );
    is_deeply(
        matching_ids( ['branch:CCC'] ),
        [ 4, 5 ],
        'branch: limit with SearchLimitLibrary=both matches home or holding branch'
    );
};

subtest 'advanced-search item operands routed to nested' => sub {
    plan tests => 7;

    # a barcode operand (idx "bc") is routed to a same-item nested term.
    is_deeply(
        matching_ids_search( undef, ['BC-A1'], ['bc'] ),
        [1],
        'a barcode operand matches the record holding that exact copy'
    );

    # an acquisition-date operand becomes a same-item range.
    is_deeply(
        matching_ids_search( undef, ['2020-01-01 - 2020-12-31'], ['acqdate,st-date-normalized'] ),
        [1],
        'an acqdate range operand matches the record with a copy acquired in that range'
    );

    # Same-item killer: record 1's 2020 copy is in AAA; its BBB copy was acquired
    # in 2019. Acqdate-2020 AND homebranch:BBB must therefore match nothing (a
    # flat cross-item query would wrongly return record 1).
    is_deeply(
        matching_ids_search(
            undef, ['2020-01-01 - 2020-12-31'], ['acqdate,st-date-normalized'], ['items.homebranch:AAA']
        ),
        [1],
        'acqdate range and library resolve on the same item (AAA copy acquired 2020)'
    );
    is_deeply(
        matching_ids_search(
            undef, ['2020-01-01 - 2020-12-31'], ['acqdate,st-date-normalized'], ['items.homebranch:BBB']
        ),
        [],
        'acqdate range and a different library do not match across items (BBB copy is 2019)'
    );

    # the mc-itype advanced-search limit is routed to items.itype.
    is_deeply(
        matching_ids_search( undef, ['*'], undef, ['mc-itype:CD'] ),
        [1],
        'mc-itype limit matches the record holding a copy of that item type'
    );

    # Empty q with only item filters must still return results (the query_string
    # falls back to "*"): "every item in library BBB" with no keyword.
    is_deeply(
        matching_ids_search( undef, [''], undef, ['items.homebranch:BBB'] ),
        [ 1, 2 ],
        'an empty q with an item filter still matches via the * fallback'
    );
    is_deeply(
        matching_ids_search( undef, [''], undef, ['mc-itype:CD'] ),
        [1],
        'an empty q with an mc-itype limit still matches via the * fallback'
    );
};

eval { $indexer->drop_index; };

done_testing();
