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

# End-to-end tests for the nested items channel (Bug 46309) against a live
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

# Mirror the production injection (F1): the throwaway index carries the nested
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
                items       => {
                    type       => 'nested',
                    properties => {
                        homebranch                    => { type => 'keyword' },
                        holdingbranch                 => { type => 'keyword' },
                        available                     => { type => 'boolean' },
                        onrequest                     => { type => 'boolean' },
                        lost                          => { type => 'keyword' },
                        hidden_in_opac_custom         => { type => 'boolean' },
                        hidden_in_opac_by_preferences => { type => 'boolean' },
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
        onrequest                     => JSON::false,
        lost                          => '0',
        hidden_in_opac_custom         => JSON::false,
        hidden_in_opac_by_preferences => JSON::false,
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
            # is on request.
            item( homebranch => 'AAA', holdingbranch => 'AAA', available => JSON::true,  onrequest => JSON::false ),
            item( homebranch => 'BBB', holdingbranch => 'BBB', available => JSON::false, onrequest => JSON::true ),
        ],
    },
    2 => {
        title       => 'river',
        items_count => 1,
        items       => [ item( homebranch => 'BBB', holdingbranch => 'BBB', available => JSON::true ) ],
    },
    3 => {
        title       => 'river',
        items_count => 0,
        items       => [],
    },
    4 => {
        title       => 'river',
        items_count => 1,
        items       => [ item( homebranch => 'CCC', holdingbranch => 'CCC', hidden_in_opac_custom => JSON::true ) ],
    },
    5 => {
        title       => 'river',
        items_count => 1,
        items =>
            [ item( homebranch => 'CCC', holdingbranch => 'CCC', hidden_in_opac_by_preferences => JSON::true ) ],
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

subtest 'same-item availability + library (R1, D1 + D3-C)' => sub {
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

subtest 'on-request filter (D2, R10)' => sub {
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

subtest 'OPAC item hiding (D6)' => sub {
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

subtest 'record suppression without user filters (D7)' => sub {
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

subtest 'library limit routed to the nested channel (D8)' => sub {
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

eval { $indexer->drop_index; };

done_testing();
